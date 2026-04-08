//
//  MainViewModel.swift
//  NetBirdiOS
//
//  Created by Pascal Fischer on 01.08.23.
//
//  This ViewModel is shared between iOS and tvOS.
//  Platform-specific code is wrapped with #if os() directives.
//

import SwiftUI
import NetworkExtension
import Network
import os
import Combine
import NetBirdSDK
import UserNotifications

/// Used by updateManagementURL to check if SSO is supported
class SSOCheckListener: NSObject, NetBirdSDKSSOListenerProtocol {
    var onResult: ((Bool?, Error?) -> Void)?

    func onError(_ p0: Error?) {
        onResult?(nil, p0)
    }

    func onSuccess(_ p0: Bool) {
        onResult?(p0, nil)
    }
}

// Error Listener for setup key login
/// Used by setSetupKey to handle async login result
class SetupKeyErrListener: NSObject, NetBirdSDKErrListenerProtocol {
    var onResult: ((Error?) -> Void)?

    func onError(_ p0: Error?) {
        onResult?(p0)
    }

    func onSuccess() {
        onResult?(nil)
    }
}

enum VPNDisplayState {
    case connected
    case connecting
    case disconnecting
    case disconnected
}

/// For both iOS and tvOS (tvOS 17+ required for VPN support).
@MainActor
class ViewModel: ObservableObject {

    private let logger = Logger(subsystem: "io.netbird.app", category: "ViewModel")

    // VPN Adapter (shared)
    @Published var networkExtensionAdapter: NetworkExtensionAdapter
    
    // UI State (shared)
    @Published var showSetupKeyPopup = false
    @Published var showChangeServerAlert = false
    @Published var showInvalidServerAlert = false
    @Published var showInvalidSetupKeyHint = false
    @Published var showInvalidSetupKeyAlert = false
    @Published var showLogLevelChangedAlert = false
    @Published var showBetaProgramAlert = false
    @Published var showInvalidPresharedKeyAlert = false
    @Published var showServerChangedInfo = false
    @Published var showPreSharedKeyChangedInfo = false
    @Published var showFqdnCopiedAlert = false
    @Published var showIpCopiedAlert = false
    @Published var showAuthenticationRequired = false
    @Published var navigateToServerView = false
    
    @Published var extensionState: NEVPNStatus = .disconnected
    @Published var managementStatus: ClientState = .disconnected
    @Published var statusDetailsValid = false
    @Published var extensionStateText = "Disconnected"
    @Published var vpnDisplayState: VPNDisplayState = .disconnected
    var connectPressed = false
    var disconnectPressed = false
    
    @Published var rosenpassEnabled = false
    @Published var rosenpassPermissive = false
    @Published var presharedKey = ""
    @Published var server: String = ""
    @Published var setupKey: String = ""
    @Published var presharedKeySecure = true
    
    @Published var fqdn = UserDefaults.standard.string(forKey: "fqdn") ?? ""
    @Published var ip = UserDefaults.standard.string(forKey: "ip") ?? ""
    
    // Debug
    @Published var traceLogsEnabled: Bool {
        didSet {
            self.showLogLevelChangedAlert = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                self.showLogLevelChangedAlert = false
            }
            let logLevel = traceLogsEnabled ? "TRACE" : "INFO"
            UserDefaults.standard.set(logLevel, forKey: "logLevel")
            UserDefaults.standard.synchronize()
        }
    }
    @Published var forceRelayConnection = true
    @Published var showForceRelayAlert = false
    @Published var connectOnDemand = false
    @Published var showOnDemandAlert = false
    @Published var showOnDemandConflictAlert = false
    @Published var showOnDemandDisconnectAlert = false
    @Published var onDemandWiFiPolicy: WiFiOnDemandPolicy = .always
    @Published var onDemandCellularPolicy: CellularOnDemandPolicy = .always
    @Published var onDemandWiFiNetworks: [String] = []
    @Published var knownSSIDs: [String] = []
    @Published var showRosenpassChangedAlert = false
    @Published var networkUnavailable = false
    @Published var isInternetConnected = true

    /// Platform-agnostic configuration provider.
    /// Abstracts iOS SDK preferences vs tvOS UserDefaults + IPC.
    private lazy var configProvider: ConfigurationProvider = ConfigurationProviderFactory.create()

    var buttonLock = false
    let defaults = UserDefaults.standard

    private var cancellables = Set<AnyCancellable>()
    private let networkMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "io.netbird.networkMonitor")
    
    @Published var peerViewModel: PeerViewModel
    @Published var routeViewModel: RoutesViewModel
    
    init() {
        let networkExtensionAdapter = NetworkExtensionAdapter()
        self.networkExtensionAdapter = networkExtensionAdapter
        let logLevel = UserDefaults.standard.string(forKey: "logLevel") ?? "INFO"
        self.traceLogsEnabled = logLevel == "TRACE"
        self.peerViewModel = PeerViewModel()
        self.routeViewModel = RoutesViewModel(networkExtensionAdapter: networkExtensionAdapter)

        // Don't load rosenpass settings during init - they trigger expensive SDK initialization.
        // These will be loaded lazily when the settings view is accessed.
        // self.rosenpassEnabled = self.getRosenpassEnabled()
        // self.rosenpassPermissive = self.getRosenpassPermissive()

        // forceRelayConnection uses UserDefaults (not SDK), so it's safe to load during init
        self.forceRelayConnection = self.getForcedRelayConnectionEnabled()
        self.connectOnDemand = self.getConnectOnDemandEnabled()
        self.loadOnDemandSettings()

        networkMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.isInternetConnected = path.status == .satisfied
                self?.updateVPNDisplayState()
            }
        }
        networkMonitor.start(queue: monitorQueue)

        $setupKey
            .removeDuplicates()
            .debounce(for: .seconds(0.5), scheduler: RunLoop.main)
            .map { setupKey in
                !self.isValidSetupKey(setupKey)
            }
            .assign(to: &$showInvalidSetupKeyHint)
    }
    
    func connect()  {
        logger.info("connect: ENTRY POINT - function called")

        #if os(iOS)
        // Check if On Demand rules would block the connection on the current interface
        if connectOnDemand && !onDemandRulesAllowConnect() {
            logger.info("connect: On Demand rules conflict with current network, showing alert")
            showOnDemandConflictAlert = true
            return
        }
        #endif

        performConnect()
    }

    /// Performs the actual VPN connection (called directly or after user dismisses On Demand conflict).
    func performConnect() {
        self.connectPressed = true
        self.buttonLock = true
        // Reset networkUnavailable flag when user initiates connection
        self.networkUnavailable = false
        #if os(iOS)
        let userDefaults = UserDefaults(suiteName: GlobalConstants.userPreferencesSuiteName)
        userDefaults?.set(false, forKey: GlobalConstants.keyNetworkUnavailable)
        userDefaults?.synchronize()
        #endif

        updateVPNDisplayState()
        logger.info("connect: connectPressed=true, buttonLock=true, starting adapter...")

        // Reset buttonLock after 3 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            self.buttonLock = false
        }

        // Start the VPN connection
        Task {
            self.logger.info("connect: Task started, calling networkExtensionAdapter.start()")
            await self.networkExtensionAdapter.start()
            self.logger.info("connect: networkExtensionAdapter.start() completed")
            // If start() returned but VPN never launched (e.g. IPC failed to get login URL)
            // and the browser login sheet is not showing, the tunnel won't start on its own.
            // Reset the stuck "Connecting..." state so the user can try again.
            if self.extensionState == .disconnected && !self.networkExtensionAdapter.showBrowser {
                self.connectPressed = false
                self.updateVPNDisplayState()
            }
        }
    }

    /// Disables On Demand and connects (user chose to override conflicting rules).
    func connectWithOnDemandDisabled() {
        setConnectOnDemand(isEnabled: false)
        performConnect()
    }

    #if os(iOS)
    /// Checks whether On Demand rules would allow a connection on the current network interface.
    /// Uses NWPathMonitor snapshot and current SSID to evaluate against saved policies.
    private func onDemandRulesAllowConnect() -> Bool {
        let path = networkMonitor.currentPath

        // Determine which interface is active
        let isOnWiFi = path.usesInterfaceType(.wifi)
        let isOnCellular = path.usesInterfaceType(.cellular)

        if isOnWiFi {
            switch onDemandWiFiPolicy {
            case .never:
                return false
            case .onlyOn:
                guard let currentSSID = getCurrentSSID(), !currentSSID.isEmpty else {
                    return false
                }
                return onDemandWiFiNetworks.contains(currentSSID)
            case .exceptOn:
                guard let currentSSID = getCurrentSSID(), !currentSSID.isEmpty else {
                    return true
                }
                return !onDemandWiFiNetworks.contains(currentSSID)
            case .always, .doNothing:
                return true
            }
        }

        if isOnCellular {
            switch onDemandCellularPolicy {
            case .never:
                return false
            case .always, .doNothing:
                return true
            }
        }

        return true
    }

    /// Checks whether On Demand has an active connect rule that will reconnect the tunnel
    /// after a manual disconnect. Unlike onDemandRulesAllowConnect(), this excludes .doNothing
    /// and only evaluates the currently active interface.
    private func onDemandWillReconnect() -> Bool {
        let path = networkMonitor.currentPath

        let isOnWiFi = path.usesInterfaceType(.wifi)
        let isOnCellular = path.usesInterfaceType(.cellular)

        if isOnWiFi {
            switch onDemandWiFiPolicy {
            case .always:
                return true
            case .onlyOn:
                guard let currentSSID = getCurrentSSID(), !currentSSID.isEmpty else {
                    return false
                }
                return onDemandWiFiNetworks.contains(currentSSID)
            case .exceptOn:
                guard let currentSSID = getCurrentSSID(), !currentSSID.isEmpty else {
                    return false
                }
                return !onDemandWiFiNetworks.contains(currentSSID)
            case .never, .doNothing:
                return false
            }
        } else if isOnCellular {
            switch onDemandCellularPolicy {
            case .always:
                return true
            case .never, .doNothing:
                return false
            }
        }

        return false
    }

    private func getCurrentSSID() -> String? {
        // Synchronous check not possible with NEHotspotNetwork.fetchCurrent()
        // Use cached value from last fetch if available
        return _cachedSSID
    }

    private var _cachedSSID: String?

    func refreshCurrentSSID() {
        NEHotspotNetwork.fetchCurrent { [weak self] network in
            DispatchQueue.main.async {
                self?._cachedSSID = network?.ssid
            }
        }
    }
    #endif
    
    func close() -> Void {
        #if os(iOS)
        // Warn user that On Demand will reconnect if rules match
        if connectOnDemand && onDemandRulesAllowConnect() {
            showOnDemandDisconnectAlert = true
            return
        }
        #endif

        performClose()
    }

    /// Performs the actual VPN disconnect.
    func performClose() {
        self.disconnectPressed = true
        DispatchQueue.main.async {
            print("Stopping extension")
            self.buttonLock = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                self.buttonLock = false
            }
            self.networkExtensionAdapter.stop()
            self.updateVPNDisplayState()
        }
    }

    /// Disables On Demand and disconnects (user chose to prevent auto-reconnect).
    func closeWithOnDemandDisabled() {
        setConnectOnDemand(isEnabled: false)
        performClose()
    }

    func updateVPNDisplayState() {
        let newState: VPNDisplayState

        // Extension state is the source of truth.
        // Flags only provide immediate UI feedback for the brief gap
        // between button press and extension state change.
        switch extensionState {
        case .connected:
            // Extension confirmed connected — clear both flags
            connectPressed = false
            disconnectPressed = false
            newState = .connected
        case .connecting:
            connectPressed = false
            newState = .connecting
        case .disconnecting:
            disconnectPressed = false
            newState = .disconnecting
        case .disconnected:
            // Extension confirmed disconnected — clear both flags,
            // unless a flag was JUST set (immediate feedback)
            if connectPressed {
                newState = .connecting
            } else {
                disconnectPressed = false
                newState = .disconnected
            }
        default:
            connectPressed = false
            disconnectPressed = false
            newState = .disconnected
        }

        vpnDisplayState = newState

        switch newState {
        case .connected:
            extensionStateText = isInternetConnected ? "Connected" : "Offline"
        case .connecting:
            extensionStateText = "Connecting..."
        case .disconnecting:
            extensionStateText = "Disconnecting..."
        case .disconnected:
            extensionStateText = "Disconnected"
        }
    }
    
    func startPollingDetails() {
        #if os(iOS)
        refreshCurrentSSID()
        #endif
        networkExtensionAdapter.startTimer { details in

            self.checkExtensionState()
            self.checkNetworkUnavailableFlag()
            self.checkLoginRequiredFlag()

            if self.extensionState == .disconnected && self.vpnDisplayState == .connected {
                self.showAuthenticationRequired = true
                self.updateVPNDisplayState()
            }

            if details.ip != self.ip || details.fqdn != self.fqdn || details.managementStatus != self.managementStatus
            {
                if !details.fqdn.isEmpty && details.fqdn != self.fqdn {
                    self.defaults.set(details.fqdn, forKey: "fqdn")
                    self.fqdn = details.fqdn
                    
                }
                if !details.ip.isEmpty && details.ip != self.ip {
                    self.defaults.set(details.ip, forKey: "ip")
                    self.ip = details.ip
                }
                print("Status: \(details.managementStatus) - Extension: \(self.extensionState)")
                
                if details.managementStatus != self.managementStatus {
                    self.managementStatus = details.managementStatus
                    self.updateVPNDisplayState()
                }
                
                // Login required detection is handled by the network extension via signalLoginRequired()
                // The app checks for this flag in checkLoginRequiredFlag() when becoming active
            }
            
            self.statusDetailsValid = true
            
            let sortedPeerInfo = details.peerInfo.sorted(by: { a, b in
                a.ip < b.ip
            })
            if sortedPeerInfo.count != self.peerViewModel.peerInfo.count || !sortedPeerInfo.elementsEqual(self.peerViewModel.peerInfo, by: { a, b in
                a.ip == b.ip && a.connStatus == b.connStatus && a.relayed == b.relayed && a.direct == b.direct && a.connStatusUpdate == b.connStatusUpdate && a.routes.count == b.routes.count
            }) {
                print("Setting new peer info: \(sortedPeerInfo.count) Peers")
                self.peerViewModel.peerInfo = sortedPeerInfo
            }
            
        }
    }
    
    func stopPollingDetails() {
        networkExtensionAdapter.stopTimer()
    }
    
    func checkExtensionState() {
        networkExtensionAdapter.getExtensionStatus { status in
            let statuses : [NEVPNStatus] = [.connected, .disconnected, .connecting, .disconnecting]
            DispatchQueue.main.async {
                if statuses.contains(status) && self.extensionState != status {
                    print("Changing extension status to \(status.rawValue)")
                    self.extensionState = status
                    self.updateVPNDisplayState()

                    if status == .connected {
                        self.routeViewModel.getRoutes()
                        // Re-enable On Demand if user has the setting turned on
                        if self.connectOnDemand {
                            self.networkExtensionAdapter.setOnDemandEnabled(true)
                        }
                    }
                }
            }
        }
    }
    
    func clearDetails() {
        self.ip = ""
        self.fqdn = ""
        defaults.removeObject(forKey: "ip")
        defaults.removeObject(forKey: "fqdn")

        // Disable and persist On Demand off to keep UI/storage/manager in sync
        setConnectOnDemand(isEnabled: false)

        // Clear config JSON (contains server credentials and all settings)
        Preferences.removeConfigFromUserDefaults()

        // Reset @Published properties to reflect cleared state in UI
        self.rosenpassEnabled = false
        self.rosenpassPermissive = false
        self.presharedKey = ""
        self.presharedKeySecure = false

        #if os(tvOS)
        // Also clear extension-local config to prevent stale credentials
        networkExtensionAdapter.clearExtensionConfig()
        #endif
    }
    
    // MARK: - Configuration Methods (via ConfigurationProvider)

    func updatePreSharedKey() {
        configProvider.preSharedKey = presharedKey
        if configProvider.commit() {
            self.close()
            self.presharedKeySecure = true
            self.showPreSharedKeyChangedInfo = true
        } else {
            print("Failed to update preshared key")
        }
    }

    func removePreSharedKey() {
        presharedKey = ""
        configProvider.preSharedKey = ""
        if configProvider.commit() {
            self.close()
            self.presharedKeySecure = false
        } else {
            print("Failed to remove preshared key")
        }
    }

    func loadPreSharedKey() {
        self.presharedKey = configProvider.preSharedKey
        self.presharedKeySecure = configProvider.hasPreSharedKey
    }

    func setRosenpassEnabled(enabled: Bool) {
        // Update @Published property for immediate UI feedback
        self.rosenpassEnabled = enabled

        // Persist to storage (on tvOS this writes directly to config JSON)
        configProvider.rosenpassEnabled = enabled
        if !configProvider.commit() {
            print("Failed to update rosenpass settings")
        }

        #if os(tvOS)
        // Show reconnect alert if currently connected
        if extensionState == .connected {
            showRosenpassChangedAlert = true
        }
        #endif
    }

    func getRosenpassEnabled() -> Bool {
        return configProvider.rosenpassEnabled
    }

    func getRosenpassPermissive() -> Bool {
        return configProvider.rosenpassPermissive
    }

    /// Loads Rosenpass settings from the configuration provider into the @Published properties.
    /// Call this when opening settings views to sync UI with stored values.
    /// On iOS, this triggers SDK initialization, so it's deferred until needed.
    /// On tvOS, this reads from UserDefaults which is fast.
    func loadRosenpassSettings() {
        self.rosenpassEnabled = configProvider.rosenpassEnabled
        self.rosenpassPermissive = configProvider.rosenpassPermissive
    }

    func setRosenpassPermissive(permissive: Bool) {
        // Update @Published property for immediate UI feedback
        self.rosenpassPermissive = permissive

        // Persist to storage (on tvOS this writes directly to config JSON)
        configProvider.rosenpassPermissive = permissive
        if !configProvider.commit() {
            print("Failed to update rosenpass permissive settings")
        }
    }

    /// Reloads configuration from persistent storage.
    /// Call this after server changes or when returning to settings view.
    func reloadConfiguration() {
        configProvider.reload()
        // Sync @Published properties with reloaded config values
        loadRosenpassSettings()
    }
    
    func setForcedRelayConnection(isEnabled: Bool) {
        let userDefaults = UserDefaults(suiteName: GlobalConstants.userPreferencesSuiteName)
        userDefaults?.set(isEnabled, forKey: GlobalConstants.keyForceRelayConnection)
        self.forceRelayConnection = isEnabled
        self.showForceRelayAlert = true
    }
    
    func getForcedRelayConnectionEnabled() -> Bool {
        let userDefaults = UserDefaults(suiteName: GlobalConstants.userPreferencesSuiteName)
        #if os(iOS)
        userDefaults?.register(defaults: [GlobalConstants.keyForceRelayConnection: true])
        return userDefaults?.bool(forKey: GlobalConstants.keyForceRelayConnection) ?? true
        #else
        // forced relay battery optimization not need on Apple Tv
        userDefaults?.register(defaults: [GlobalConstants.keyForceRelayConnection: false])
        return userDefaults?.bool(forKey: GlobalConstants.keyForceRelayConnection) ?? false
        #endif
    }
    
    func setConnectOnDemand(isEnabled: Bool) {
        let userDefaults = UserDefaults(suiteName: GlobalConstants.userPreferencesSuiteName)
        userDefaults?.set(isEnabled, forKey: GlobalConstants.keyConnectOnDemand)
        self.connectOnDemand = isEnabled
        networkExtensionAdapter.setOnDemandEnabled(isEnabled)
        if isEnabled {
            self.showOnDemandAlert = true
        }
    }

    func getConnectOnDemandEnabled() -> Bool {
        let userDefaults = UserDefaults(suiteName: GlobalConstants.userPreferencesSuiteName)
        return userDefaults?.bool(forKey: GlobalConstants.keyConnectOnDemand) ?? false
    }

    func loadOnDemandSettings() {
        let userDefaults = UserDefaults(suiteName: GlobalConstants.userPreferencesSuiteName)
        let wifiRaw = userDefaults?.string(forKey: GlobalConstants.keyOnDemandWiFiPolicy) ?? WiFiOnDemandPolicy.always.rawValue
        let cellularRaw = userDefaults?.string(forKey: GlobalConstants.keyOnDemandCellularPolicy) ?? CellularOnDemandPolicy.always.rawValue
        self.onDemandWiFiPolicy = WiFiOnDemandPolicy(rawValue: wifiRaw) ?? .always
        self.onDemandCellularPolicy = CellularOnDemandPolicy(rawValue: cellularRaw) ?? .always
        self.onDemandWiFiNetworks = userDefaults?.stringArray(forKey: GlobalConstants.keyOnDemandWiFiNetworks) ?? []
        self.knownSSIDs = userDefaults?.stringArray(forKey: GlobalConstants.keyKnownSSIDs) ?? []
    }

    func saveOnDemandSettings() {
        let userDefaults = UserDefaults(suiteName: GlobalConstants.userPreferencesSuiteName)
        userDefaults?.set(onDemandWiFiPolicy.rawValue, forKey: GlobalConstants.keyOnDemandWiFiPolicy)
        userDefaults?.set(onDemandCellularPolicy.rawValue, forKey: GlobalConstants.keyOnDemandCellularPolicy)
        userDefaults?.set(onDemandWiFiNetworks, forKey: GlobalConstants.keyOnDemandWiFiNetworks)

        if connectOnDemand {
            networkExtensionAdapter.applyOnDemandRules(
                wifiPolicy: onDemandWiFiPolicy,
                cellularPolicy: onDemandCellularPolicy,
                wifiNetworks: onDemandWiFiNetworks
            )
        }
    }

    func addOnDemandWiFiNetwork(_ ssid: String) {
        let trimmed = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !onDemandWiFiNetworks.contains(trimmed) else { return }
        onDemandWiFiNetworks.append(trimmed)
        saveOnDemandSettings()
    }

    func removeOnDemandWiFiNetwork(at offsets: IndexSet) {
        onDemandWiFiNetworks.remove(atOffsets: offsets)
        saveOnDemandSettings()
    }

    func recordKnownSSID(_ ssid: String) {
        let trimmed = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !knownSSIDs.contains(trimmed) else { return }
        knownSSIDs.append(trimmed)
        let userDefaults = UserDefaults(suiteName: GlobalConstants.userPreferencesSuiteName)
        userDefaults?.set(knownSSIDs, forKey: GlobalConstants.keyKnownSSIDs)
    }

    func removeKnownSSID(_ ssid: String) {
        knownSSIDs.removeAll { $0 == ssid }
        let userDefaults = UserDefaults(suiteName: GlobalConstants.userPreferencesSuiteName)
        userDefaults?.set(knownSSIDs, forKey: GlobalConstants.keyKnownSSIDs)
    }

    func getDefaultStatus() -> StatusDetails {
        return StatusDetails(ip: "", fqdn: "", managementStatus: .disconnected, peerInfo: [])
    }
    
    func isValidSetupKey(_ string: String) -> Bool {
        if string.isEmpty { return true }
        let pattern = "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
        let isMatch = string.range(of: pattern, options: .regularExpression, range: nil, locale: nil) != nil
        return isMatch
    }
    
    func printLogContents(from logURL: URL) {
        do {
            let logContents = try String(contentsOf: logURL, encoding: .utf8)
            print(logContents)
        } catch {
            print("Failed to read the log file: \(error.localizedDescription)")
        }
    }

    /// Handles server change completion by stopping the engine and resetting all connection state.
    func handleServerChanged() {
        AppLogger.shared.log("Server changed - stopping engine and resetting state")

        // Stop polling to prevent transitional states from updating UI
        stopPollingDetails()
        
        // Reset connection flags first to update UI immediately
        connectPressed = false
        disconnectPressed = false
        buttonLock = false

        // Reset connection state
        extensionState = .disconnected
        managementStatus = .disconnected
        updateVPNDisplayState()

        // Clear peer info
        peerViewModel.peerInfo = []

        // Clear connection details
        clearDetails()
 
        // Stop the network extension in background (non-blocking)
        Task { @MainActor in
            self.networkExtensionAdapter.stop()
        }

        // Reload configuration for new server
        reloadConfiguration()
    }

    /// Checks shared app-group container for network unavailable flag set by the network extension.
    /// Updates the networkUnavailable property to trigger UI animation changes.
    /// iOS only - tvOS has a platform limitation where `UserDefaults(suiteName:)` does not
    /// reliably synchronize between the main app and network extension processes, even with
    /// a correctly configured App Group. On tvOS, we use IPC messaging instead.
    func checkNetworkUnavailableFlag() {
        #if os(iOS)
        let userDefaults = UserDefaults(suiteName: GlobalConstants.userPreferencesSuiteName)
        let isUnavailable = userDefaults?.bool(forKey: GlobalConstants.keyNetworkUnavailable) ?? false

        if isUnavailable != networkUnavailable {
            AppLogger.shared.log("Network unavailable flag changed: \(isUnavailable)")
            networkUnavailable = isUnavailable
            updateVPNDisplayState()
        }
        #endif
        // tvOS: Network status is determined by extension state, not a shared flag
    }

    /// Checks shared app-group container for login required flag set by the network extension.
    /// If set, schedules a local notification (if authorized) and shows the authentication UI.
    /// iOS only - tvOS cannot share UserDefaults between app and extension, and uses IPC
    /// via `checkLoginError` instead.
    func checkLoginRequiredFlag() {
        #if os(iOS)
        let userDefaults = UserDefaults(suiteName: GlobalConstants.userPreferencesSuiteName)
        guard userDefaults?.bool(forKey: GlobalConstants.keyLoginRequired) == true else {
            return
        }

        // Clear the flag immediately
        userDefaults?.set(false, forKey: GlobalConstants.keyLoginRequired)
        userDefaults?.synchronize()

        AppLogger.shared.log("Login required flag detected from extension")

        // Show authentication required UI
        self.showAuthenticationRequired = true

        // Clear any stuck "Connecting..." state
        self.connectPressed = false
        self.updateVPNDisplayState()

        // Temporarily disable On Demand to stop iOS from looping reconnect attempts
        // while the user is not authenticated. It will be re-enabled automatically
        // after a successful connection (see checkExtensionState).
        self.networkExtensionAdapter.setOnDemandEnabled(false)

        // Schedule local notification if authorized
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else {
                AppLogger.shared.log("Notifications not authorized, skipping notification")
                return
            }

            let content = UNMutableNotificationContent()
            content.title = "NetBird"
            content.body = "Login required. Please open the app to reconnect."
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "netbird.login.required",
                content: content,
                trigger: nil
            )

            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    AppLogger.shared.log("Failed to schedule login notification: \(error.localizedDescription)")
                } else {
                    AppLogger.shared.log("Login required notification scheduled from main app")
                }
            }
        }
        #endif
        // tvOS: Login errors are detected via IPC (checkLoginError in TVAuthView)
    }
}
