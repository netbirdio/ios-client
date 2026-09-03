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
import UIKit
#if os(iOS)
import WidgetKit
#endif

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
    @Published var navigateToProfilesView = false

    #if os(iOS)
    @Published var activeProfileName: String = ProfileManager.shared.getActiveProfileName()
    #endif

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
    
    @Published var fqdn = ""
    @Published var ip = ""
    @Published var ipv6 = ""
    
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

    // Troubleshoot / Debug Bundle
    enum DebugBundleUploadState {
        case idle
        case uploading
        case done(key: String)
        case error(message: String)
    }

    @Published var anonymizeDebugBundle: Bool {
        didSet {
            UserDefaults.standard.set(anonymizeDebugBundle, forKey: "netbird.anonymizeDebugBundle")
        }
    }
    @Published var debugBundleUploadState: DebugBundleUploadState = .idle
    @Published var forceRelayConnection = true
    @Published var showForceRelayAlert = false
    @Published var disableIPv6 = false
    @Published var connectOnDemand = false
    @Published var showOnDemandAlert = false
    @Published var showOnDemandConflictAlert = false
    @Published var showOnDemandDisconnectAlert = false
    @Published var onDemandWiFiPolicy: WiFiOnDemandPolicy = .always
    @Published var onDemandCellularPolicy: CellularOnDemandPolicy = .always
    @Published var onDemandWiFiNetworks: [String] = []
    @Published var knownSSIDs: [String] = []
    @Published var showRosenpassChangedAlert = false
    /// MDM enforcement snapshot rendered by the Go layer. `.empty` means no
    /// policy is in force, which is also the state on any read failure - a
    /// broken policy must not lock the user out of their own settings.
    @Published var mdmRestrictions: MDMRestrictions = .empty
    @Published var showSettingsRejectedAlert = false
    @Published var showMDMPolicyAppliedToast = false
    /// Reason shown by the settings-rejected alert.
    var settingsRejectedMessage = ""
    @Published var networkUnavailable = false
    @Published var isInternetConnected = true

    /// Platform-agnostic configuration provider.
    /// Abstracts iOS SDK preferences vs tvOS UserDefaults + IPC.
    private lazy var configProvider: ConfigurationProvider = ConfigurationProviderFactory.create()

    var buttonLock = false
    let defaults = UserDefaults.standard

    // MARK: - Per-profile connection info

    #if os(iOS)
    private let profileConnectionCache = ProfileConnectionCache()
    #endif

    /// While true the polling timer must not overwrite ip/fqdn/peers.
    /// Set when switching profiles; cleared once the extension fully
    /// disconnects and then reconnects to the new profile.
    private var profileSwitchPending = false
    private var previousExtensionState: NEVPNStatus = .disconnected

    /// Loads cached ip/fqdn for the given profile into the published properties.
    /// Shows empty strings if no data has been saved for that profile yet.
    func loadConnectionInfoForProfile(forID id: String) {
        #if os(iOS)
        let entry = profileConnectionCache.entry(forID: id)
        ip   = entry?.ip   ?? ""
        fqdn = entry?.fqdn ?? ""
        ipv6 = entry?.ipv6 ?? ""
        #endif
    }

    private var cancellables = Set<AnyCancellable>()
    private let networkMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "io.netbird.networkMonitor")
    #if os(iOS)
    private var vpnStatusObserver: NSObjectProtocol?
    private var mdmConfigObserver: NSObjectProtocol?
    private var mdmRefreshWorkItem: DispatchWorkItem?
    #endif
    /// Outside the iOS-only block above: both platforms poll for a policy the
    /// OS may have pushed from another process.
    private var lastMDMPolicyCheck = Date.distantPast
    
    @Published var peerViewModel: PeerViewModel
    @Published var routeViewModel: RoutesViewModel
    
    init() {
        let networkExtensionAdapter = NetworkExtensionAdapter()
        self.networkExtensionAdapter = networkExtensionAdapter
        let logLevel = UserDefaults.standard.string(forKey: "logLevel") ?? "INFO"
        self.traceLogsEnabled = logLevel == "TRACE"
        self.anonymizeDebugBundle = UserDefaults.standard.bool(forKey: "netbird.anonymizeDebugBundle")
        self.peerViewModel = PeerViewModel()
        self.routeViewModel = RoutesViewModel(networkExtensionAdapter: networkExtensionAdapter)

        // Load cached connection info for the active profile
        #if os(iOS)
        let activeProfileID = ProfileManager.shared.getActiveProfileID()
        let cache = ProfileConnectionCache()
        let cached = cache.entry(forID: activeProfileID)
        self.ip   = cached?.ip   ?? ""
        self.fqdn = cached?.fqdn ?? ""
        self.ipv6 = cached?.ipv6 ?? ""
        #endif

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

        #if os(iOS)
        // Observe VPN status changes even in background to deliver reliable local notifications.
        // UNUserNotificationCenter in NEPacketTunnelProvider is unreliable — sending from
        // the main app process is the only way notifications are guaranteed to be delivered.
        vpnStatusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleVPNStatusChangeForNotification()
        }

        // Catches policy writes this process makes itself. It will NOT fire
        // for the OS writing managed configuration from another process -
        // UserDefaults.didChangeNotification is process-local, and KVO cannot
        // help either because the key contains dots and would be read as a
        // key path. An externally pushed policy is therefore picked up on the
        // next activation (see startActivation) or when a screen appears.
        //
        // The channel is shared with every other preference write, so the
        // refresh is debounced. The main app has no restart decision to make;
        // that lives in the extension, where hasMDMPolicyChanged() diffs.
        mdmConfigObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleMDMRestrictionsRefresh()
        }
        #endif

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
        // Dismiss any pending auth alert: the user is starting a fresh connect/login
        // cycle, so a stale "authentication required" state is no longer relevant.
        self.showAuthenticationRequired = false
        #if os(iOS)
        let userDefaults = UserDefaults(suiteName: GlobalConstants.userPreferencesSuiteName)
        userDefaults?.set(false, forKey: GlobalConstants.keyNetworkUnavailable)
        // Clear any login-required flag left over from a previous session/extension run.
        // Otherwise the polling timer's checkLoginRequiredFlag() fires immediately on
        // connect and pops the "Login required" alert in parallel with the browser login
        // flow that performLogin() is already starting. A genuinely required re-auth will
        // be re-signalled by the extension *after* this connect attempt.
        userDefaults?.set(false, forKey: GlobalConstants.keyLoginRequired)
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
            // start() returns as soon as startVPNTunnel() is called — the tunnel process
            // hasn't launched yet and extensionState is still .disconnected at this point.
            // Wait long enough for the tunnel to start and for the polling cycle to pick up
            // the new NEVPNStatus before deciding whether the launch genuinely failed.
            try? await Task.sleep(nanoseconds: 8_000_000_000) // 8 seconds
            // If after the wait the state is still disconnected and no browser login sheet
            // is visible, the tunnel failed to start (e.g. IPC error). Reset the stuck
            // "Connecting..." state so the user can try again.
            if self.extensionState == .disconnected && !self.networkExtensionAdapter.showBrowser {
                self.connectPressed = false
                self.updateVPNDisplayState()
            }
        }
    }

    /// Disables On Demand and connects (user chose to override conflicting rules).
    /// Connects only once the disarm has been written, otherwise a Disconnect rule that is
    /// still in force tears the new tunnel down again. The connect runs even if the manager
    /// refused the change — the user asked for a connection, and the rule conflict is
    /// reported by the alert that led here.
    func connectWithOnDemandDisabled() {
        setConnectOnDemand(isEnabled: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.performConnect()
            }
        }
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
        // The policy holds the rules disarmed, so nothing will reconnect and
        // there is nothing to warn about. Prompting here would also route the
        // user into closeWithOnDemandDisabled(), which writes the saved
        // preference to false - the one value the policy is deliberately
        // preserving so it can be restored when the restriction lifts.
        guard !autoConnectForbiddenByPolicy else {
            performClose()
            return
        }

        #if os(iOS)
        // Warn user that On Demand will reconnect if rules match
        if connectOnDemand && onDemandRulesAllowConnect() {
            showOnDemandDisconnectAlert = true
            return
        }
        #else
        // tvOS runs a single always-connect rule, so an armed On Demand reconnects
        // immediately on any interface — always warn before a manual disconnect.
        if connectOnDemand {
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

    /// Called when the user dismisses the interactive login browser without completing
    /// login. Resets the "Connecting…" state back to disconnected and clears any
    /// login-required signalling so no spurious auth alert/notification is shown — the
    /// user simply chose not to log in, which is not a failed active session.
    func cancelPendingLogin() {
        connectPressed = false
        showAuthenticationRequired = false
        #if os(iOS)
        // Abort the SDK login so its PKCE loopback server is torn down and its port
        // freed — otherwise the next connect stalls trying to bind the same port.
        networkExtensionAdapter.cancelLogin()
        let userDefaults = UserDefaults(suiteName: GlobalConstants.userPreferencesSuiteName)
        userDefaults?.set(false, forKey: GlobalConstants.keyLoginRequired)
        userDefaults?.synchronize()
        #endif
        updateVPNDisplayState()
    }

    /// Disables On Demand and disconnects (user chose to prevent auto-reconnect).
    /// The disconnect waits for the disarm to be persisted: stopping the tunnel while a rule
    /// is still in force just has the system bring it back, which reads as a failed
    /// disconnect. If the manager refuses the change, the tunnel is left up rather than
    /// dropped into an immediate reconnect.
    func closeWithOnDemandDisabled() {
        setConnectOnDemand(isEnabled: false) { [weak self] inForce in
            guard inForce else {
                AppLogger.shared.log("closeWithOnDemandDisabled: On Demand still armed, keeping the tunnel up")
                return
            }
            DispatchQueue.main.async {
                self?.performClose()
            }
        }
    }

    func updateVPNDisplayState(priorExtensionState: NEVPNStatus? = nil) {
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
            // Do NOT clear connectPressed here — iOS can emit .disconnecting right after
            // .connecting during tunnel startup (cleanup of old instance). Keeping
            // connectPressed=true lets the .disconnecting handler suppress that noise.
            // connectPressed is cleared only on .connected or .disconnected.
            newState = .connecting
        case .disconnecting:
            // Ignore transient .disconnecting emitted by iOS VPN framework during tunnel startup.
            // When startVPNTunnel() is called, iOS briefly reports .disconnecting while cleaning
            // up the previous tunnel instance — even though the user pressed Connect, not Disconnect.
            // connectPressed handles this for app-initiated connects.
            // priorExtensionState handles widget-initiated connects where connectPressed is never set.
            let wasConnecting = priorExtensionState == .connecting
            if connectPressed || wasConnecting {
                newState = .connecting
            } else {
                disconnectPressed = false
                newState = .disconnecting
            }
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

        #if os(iOS)
        updateWidgetState()
        #endif
    }

    #if os(iOS)
    /// Writes current VPN state to shared UserDefaults so the widget can read it.
    private func updateWidgetState() {
        let userDefaults = UserDefaults(suiteName: GlobalConstants.userPreferencesSuiteName)
        let statusString: String
        switch vpnDisplayState {
        case .connected: statusString = "connected"
        case .connecting: statusString = "connecting"
        case .disconnecting: statusString = "disconnecting"
        case .disconnected: statusString = "disconnected"
        }
        userDefaults?.set(statusString, forKey: GlobalConstants.keyWidgetVPNStatus)
        userDefaults?.set(ip, forKey: GlobalConstants.keyWidgetIP)
        userDefaults?.set(fqdn, forKey: GlobalConstants.keyWidgetFQDN)
        WidgetCenter.shared.reloadAllTimelines()
        if #available(iOS 18.0, *) {
            ControlCenter.shared.reloadControls(ofKind: "io.netbird.vpn.control")
        }
    }
    #endif

    func startPollingDetails() {
        #if os(iOS)
        refreshCurrentSSID()
        #endif
        networkExtensionAdapter.startTimer { details in
            self.checkExtensionState()
            self.checkNetworkUnavailableFlag()
            self.checkLoginRequiredFlag()
            self.refreshMDMRestrictionsIfStale()

            let currentState = self.extensionState

            // Detect reconnection after a profile switch:
            // the guard lifts only once the extension has gone through a
            // non-connected state and then comes back as .connected.
            if self.profileSwitchPending {
                if self.previousExtensionState != .connected && currentState == .connected {
                    self.profileSwitchPending = false
                }
                self.previousExtensionState = currentState
            }

            if currentState == .disconnected && self.vpnDisplayState == .connected {
                self.showAuthenticationRequired = true
                self.updateVPNDisplayState()
            }

            // Only update ip/fqdn/peers when the extension is connected
            // AND we are not mid-profile-switch (guard ensures we don't
            // overwrite the new profile's cached data with the old tunnel's values).
            if !self.profileSwitchPending && currentState == .connected {
                let newFqdn = details.fqdn.isEmpty ? self.fqdn : details.fqdn
                let newIp   = details.ip.isEmpty   ? self.ip   : details.ip
                let newIpv6 = details.ipv6 ?? self.ipv6
                let changed = newFqdn != self.fqdn || newIp != self.ip || newIpv6 != self.ipv6
                if changed {
                    self.fqdn = newFqdn
                    self.ip   = newIp
                    self.ipv6 = newIpv6
                    #if os(iOS)
                    let activeID = ProfileManager.shared.getActiveProfileID()
                    self.profileConnectionCache.save(ip: newIp, fqdn: newFqdn, ipv6: newIpv6, forID: activeID)
                    #endif
                }

                let sortedPeerInfo = details.peerInfo.sorted { $0.ip < $1.ip }
                if sortedPeerInfo.count != self.peerViewModel.peerInfo.count || !sortedPeerInfo.elementsEqual(self.peerViewModel.peerInfo, by: { a, b in
                    a.ip == b.ip && a.connStatus == b.connStatus && a.relayed == b.relayed && a.direct == b.direct && a.connStatusUpdate == b.connStatusUpdate && a.routes.count == b.routes.count
                }) {
                    print("Setting new peer info: \(sortedPeerInfo.count) Peers")
                    self.peerViewModel.peerInfo = sortedPeerInfo
                }
            }

            if details.managementStatus != self.managementStatus {
                print("Status: \(details.managementStatus) - Extension: \(currentState)")
                self.managementStatus = details.managementStatus
                self.updateVPNDisplayState()
            }

            self.statusDetailsValid = true
        }
    }
    
    func stopPollingDetails() {
        networkExtensionAdapter.stopTimer()
    }
    
    // Prevents overlapping getExtensionStatus calls from delivering out-of-order results.
    // loadAllFromPreferences() is slow and variable; without this guard a stale .disconnecting
    // completion can arrive after a newer .disconnected one, causing a spurious Disconnecting flash.
    private var isCheckingExtensionState = false

    func checkExtensionState() {
        guard !isCheckingExtensionState else { return }
        isCheckingExtensionState = true
        networkExtensionAdapter.getExtensionStatus { status in
            DispatchQueue.main.async {
                self.isCheckingExtensionState = false
                self.applyExtensionStatus(status)
            }
        }
    }

    private func applyExtensionStatus(_ status: NEVPNStatus) {
        let knownStatuses: Set<NEVPNStatus> = [.connected, .disconnected, .connecting, .disconnecting]
        guard knownStatuses.contains(status), extensionState != status else { return }

        let priorState = extensionState
        extensionState = status
        updateVPNDisplayState(priorExtensionState: priorState)

        applyRouteSideEffects(for: status)

        // `connectOnDemand` is the user's saved preference, which the policy
        // deliberately leaves intact so it can be restored later - so it is
        // not on its own permission to arm the rules.
        if status == .connected, connectOnDemand, !autoConnectForbiddenByPolicy {
            networkExtensionAdapter.setOnDemandEnabled(true)
        }
    }

    /// Brings the cached route list in line with `status`.
    ///
    /// Separate from `applyExtensionStatus` so that callers which assign `extensionState`
    /// themselves — and therefore trip its `extensionState != status` guard — can still
    /// apply this part. Idempotent: re-running it for an unchanged status costs one
    /// GetRoutes round-trip while connected, and nothing at all while disconnected.
    func applyRouteSideEffects(for status: NEVPNStatus) {
        if status == .connected {
            routeViewModel.getRoutes()
        } else if status == .disconnected {
            // Routes only exist while the extension is up. Drop them so the exit node
            // selector on the connection screen falls back to its disabled state instead
            // of listing nodes that can no longer be applied. The core keeps the actual
            // selection, so it comes back with the next getRoutes on reconnect.
            routeViewModel.clearRoutes()
        }
    }
    
    func clearDetails() {
        self.ip = ""
        self.fqdn = ""
        self.ipv6 = ""
        defaults.removeObject(forKey: "ip")
        defaults.removeObject(forKey: "fqdn")

        // Disable and persist On Demand off to keep UI/storage/manager in sync, and wipe the
        // config only once that disarm has actually landed — a rule still in force would have
        // the system restart the tunnel against the configuration being removed.
        if connectOnDemand {
            setConnectOnDemand(isEnabled: false) { [weak self] inForce in
                if !inForce {
                    AppLogger.shared.log("clearDetails: On Demand disarm failed, clearing the config anyway")
                }
                DispatchQueue.main.async {
                    self?.wipeStoredConfig()
                }
            }
        } else {
            wipeStoredConfig()
        }

        // Reset @Published properties to reflect cleared state in UI
        self.rosenpassEnabled = false
        self.rosenpassPermissive = false
        self.presharedKey = ""
        self.presharedKeySecure = false
    }

    /// Removes the stored configuration — server credentials and all settings.
    private func wipeStoredConfig() {
        Preferences.removeConfigFromUserDefaults()

        #if os(tvOS)
        // Also clear extension-local config to prevent stale credentials
        networkExtensionAdapter.clearExtensionConfig()
        #endif
    }

    /// Server change: disarm On Demand, then disconnect and clear local state, in that order.
    /// Proceeds even when the disarm fails — the user asked to leave this server, and stale
    /// credentials must not be kept just because the tunnel manager refused a rule change.
    func resetForServerChange(completion: @escaping () -> Void) {
        refreshMDMRestrictions()
        guard !mdmRestrictions.mdm.managesManagementURL,
              !mdmRestrictions.features.disableUpdateSettings else {
            AppLogger.shared.log("MDM: refusing to reset for a server change while the server is managed")
            settingsRejectedMessage = "The server for this device is set by your organization."
            showSettingsRejectedAlert = true
            return
        }
        setConnectOnDemand(isEnabled: false) { [weak self] inForce in
            DispatchQueue.main.async {
                guard let self else { return }
                if !inForce {
                    AppLogger.shared.log("resetForServerChange: On Demand disarm failed, resetting anyway")
                }
                self.performClose()
                self.clearDetails()
                completion()
            }
        }
    }
    
    // MARK: - Configuration Methods (via ConfigurationProvider)

    /// Whether the policy owns the pre-shared key, by managing it directly or
    /// by forbidding settings edits at all.
    private var preSharedKeyForbiddenByPolicy: Bool {
        mdmRestrictions.mdm.preSharedKey || mdmRestrictions.features.disableUpdateSettings
    }

    func updatePreSharedKey() {
        // The only backstop on tvOS: commit() there writes straight to the
        // config JSON and always reports success, so a policy that arrives
        // while a key-entry alert is open would otherwise be overwritten.
        guard !preSharedKeyForbiddenByPolicy else {
            AppLogger.shared.log("MDM: refusing to change the pre-shared key while it is managed")
            settingsRejectedMessage = "This setting is managed by your organization and cannot be changed."
            showSettingsRejectedAlert = true
            return
        }
        configProvider.setPreSharedKey(presharedKey)
        if commitSettings() {
            // tvOS: bypass the On Demand disconnect prompt. The user changed a setting that
            // needs a reconnect, not asked to stay offline — letting On Demand bring the
            // tunnel back with the new key is the intended outcome (and the prompt would be
            // hidden behind the pre-shared key cover anyway).
            #if os(tvOS)
            self.performClose()
            #else
            self.close()
            #endif
            self.presharedKeySecure = true
            self.showPreSharedKeyChangedInfo = true
        } else {
            print("Failed to update preshared key")
        }
    }

    func removePreSharedKey() {
        guard !preSharedKeyForbiddenByPolicy else {
            AppLogger.shared.log("MDM: refusing to remove the pre-shared key while it is managed")
            settingsRejectedMessage = "This setting is managed by your organization and cannot be changed."
            showSettingsRejectedAlert = true
            return
        }
        presharedKey = ""
        configProvider.setPreSharedKey("")
        if commitSettings() {
            #if os(tvOS)
            self.performClose()
            #else
            self.close()
            #endif
            self.presharedKeySecure = false
        } else {
            print("Failed to remove preshared key")
        }
    }

    /// Commits staged settings and turns an MDM rejection into an explanation.
    ///
    /// Preferences.commit() refuses a staged value that diverges from a
    /// managed key. That is a backstop, not the primary UX - the control
    /// should already have been locked - so reaching it means this process
    /// held a stale view of the policy, and the snapshot is re-read.
    @discardableResult
    private func commitSettings() -> Bool {
        if configProvider.commit() {
            return true
        }
        let reason = configProvider.lastCommitError ?? ""
        refreshMDMRestrictions()
        if reason.localizedCaseInsensitiveContains("managed by MDM") {
            settingsRejectedMessage = "This setting is managed by your organization and cannot be changed."
        } else {
            settingsRejectedMessage = reason.isEmpty
                ? "The setting could not be saved."
                : reason
        }
        showSettingsRejectedAlert = true
        return false
    }

    /// Re-reads the MDM enforcement snapshot. Cheap: getRestrictionsJSON()
    /// consults only the policy loader and never touches the config file.
    /// Call it from onAppear of any screen that hides or locks controls.
    func refreshMDMRestrictions() {
        lastMDMPolicyCheck = Date()
        let snapshot = MDMRestrictions.current()
        // Equatable guards against republishing an identical snapshot and
        // redrawing every settings screen on unrelated UserDefaults writes.
        guard snapshot != mdmRestrictions else { return }
        let autoConnectWasManaged = mdmRestrictions.mdm.disableAutoConnect
        mdmRestrictions = snapshot

        if snapshot.mdm.disableAutoConnect != autoConnectWasManaged {
            applyAutoConnectPolicy(snapshot.mdm.disableAutoConnect)
        }

        // The lock flags alone are not enough: a policy that starts enforcing
        // Rosenpass or a pre-shared key while a settings screen is open would
        // leave the now-locked control showing the user's old value. The
        // getters return the enforced value once a key is managed, so re-read
        // them here rather than waiting for the next onAppear.
        loadRosenpassSettings()
        presharedKeySecure = configProvider.hasPreSharedKey
    }

    // Only iOS subscribes to the managed-config change channel; the tvOS
    // screens re-read the snapshot in onAppear instead.
    /// Bounds how long an externally pushed policy can go unnoticed while the
    /// app stays in the foreground.
    ///
    /// The OS writes managed configuration from another process, so the
    /// in-process change notification never fires for it, and KVO cannot stand
    /// in because the key's dots would be read as a key path. Activation
    /// covers a policy that arrived while the app was away; this covers one
    /// that arrives while it is open. Throttled well below the three-second
    /// tick it rides on - the read crosses into Go.
    private func refreshMDMRestrictionsIfStale() {
        guard Date().timeIntervalSince(lastMDMPolicyCheck) >= 30 else { return }
        refreshMDMRestrictions()
    }

    /// Whether the policy forbids the daemon from connecting on its own.
    ///
    /// Every path that arms the VPN profile's On Demand rules has to consult
    /// this, not just the user's preference: the rules live in the OS profile
    /// and outlive any single connection, so one unguarded re-arm restores
    /// automatic connection for good.
    private var autoConnectForbiddenByPolicy: Bool {
        mdmRestrictions.mdm.disableAutoConnect
    }

    /// Arms or disarms the VPN profile's On Demand rules to match the policy.
    ///
    /// `disableAutoConnect` forbids connecting without the user asking, but On
    /// Demand lives in the OS VPN profile, not in the engine - locking the
    /// toggle changes nothing for a device whose rules are already armed, and
    /// it would keep reconnecting. The user's saved preference is left alone
    /// so it can be restored if the policy is lifted.
    private func applyAutoConnectPolicy(_ managed: Bool) {
        if managed {
            guard networkExtensionAdapter.isOnDemandEnabled else { return }
            AppLogger.shared.log("MDM: disableAutoConnect enforced — disarming On Demand rules")
            networkExtensionAdapter.setOnDemandEnabled(false)
            return
        }

        let userDefaults = UserDefaults(suiteName: GlobalConstants.userPreferencesSuiteName)
        let saved = userDefaults?.bool(forKey: GlobalConstants.keyConnectOnDemand) ?? false
        guard saved, !networkExtensionAdapter.isOnDemandEnabled else { return }
        AppLogger.shared.log("MDM: disableAutoConnect lifted — restoring the user's On Demand setting")
        networkExtensionAdapter.setOnDemandEnabled(true)
    }

    #if os(iOS)
    private func scheduleMDMRestrictionsRefresh() {
        mdmRefreshWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.refreshMDMRestrictions()
        }
        mdmRefreshWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }
    #endif

    func loadPreSharedKey() {
        // The key itself is no longer readable across the bridge - the screen
        // shows only whether one is configured, and the staging field starts
        // empty so a save always submits a value the user just typed.
        self.presharedKey = ""
        self.presharedKeySecure = configProvider.hasPreSharedKey
    }

    func setRosenpassEnabled(enabled: Bool) {
        // Update @Published property for immediate UI feedback
        self.rosenpassEnabled = enabled

        // Persist to storage (on tvOS this writes directly to config JSON)
        configProvider.rosenpassEnabled = enabled
        if !commitSettings() {
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
        if !commitSettings() {
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

    /// Switches connection display data to the given profile's cached values.
    /// Call this when switching profiles so the new profile's last known info is shown immediately.
    func switchConnectionInfo(toID id: String) {
        // Load cached data for the target profile so the UI shows it right away.
        loadConnectionInfoForProfile(forID: id)
        peerViewModel.peerInfo = []
        managementStatus = .disconnected
        updateVPNDisplayState()
        // Block polling from overwriting the new profile's data until the extension
        // has fully disconnected and reconnected to the new profile.
        // Seed previousExtensionState with the CURRENT extension state so the guard
        // only fires on a genuine non-connected → connected transition.
        // (Setting it to .disconnected would falsely trigger on the very next tick
        // while the old tunnel is still connected.)
        profileSwitchPending = true
        previousExtensionState = extensionState
    }
    
    func setDisableIPv6(disabled: Bool) {
        let previous = self.disableIPv6
        self.disableIPv6 = disabled
        configProvider.disableIPv6 = disabled
        if !commitSettings() {
            print("Failed to update IPv6 settings")
            self.disableIPv6 = previous
            configProvider.disableIPv6 = previous
        }
    }

    func loadIPv6Settings() {
        self.disableIPv6 = configProvider.disableIPv6
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
    
    /// Stores the user's On Demand choice and asks the tunnel manager to apply it.
    ///
    /// The preference is written up front because it is the user's *intent*: when there is
    /// nothing to arm yet (no manager, or no login), the choice has to survive so
    /// `applyExtensionStatus` can arm it after the next successful connection. Only a manager
    /// that actively rejects the change rolls the stored value back, so UI, storage and the
    /// tunnel manager never disagree about what is in force.
    ///
    /// - Parameter completion: called with `true` when the requested state is in force
    ///   (applied, or nothing needed arming), `false` when the manager refused it. Callers
    ///   that depend on the change — disconnecting, wiping the config — must wait for it.
    func setConnectOnDemand(isEnabled: Bool, completion: ((Bool) -> Void)? = nil) {
        // Backstop behind the locked control: the rules must not be armed
        // while the policy forbids automatic connection, whatever route got
        // here.
        if isEnabled, autoConnectForbiddenByPolicy {
            AppLogger.shared.log("MDM: refusing to arm On Demand while disableAutoConnect is enforced")
            completion?(false)
            return
        }
        let previous = connectOnDemand
        let userDefaults = UserDefaults(suiteName: GlobalConstants.userPreferencesSuiteName)
        userDefaults?.set(isEnabled, forKey: GlobalConstants.keyConnectOnDemand)
        self.connectOnDemand = isEnabled
        networkExtensionAdapter.setOnDemandEnabled(isEnabled) { [weak self] result in
            switch result {
            case .applied, .deferred:
                completion?(true)
            case .failed(let error):
                AppLogger.shared.log("On Demand change to \(isEnabled) failed (\(error?.localizedDescription ?? "unknown error")), reverting to \(previous)")
                DispatchQueue.main.async {
                    userDefaults?.set(previous, forKey: GlobalConstants.keyConnectOnDemand)
                    self?.connectOnDemand = previous
                    completion?(false)
                }
            }
        }
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
        // The confirmation alert stays presented across a policy change, so
        // re-read before acting: clearDetails() below erases the stored
        // configuration, which must not happen once the server is enforced.
        refreshMDMRestrictions()
        guard !mdmRestrictions.mdm.managesManagementURL,
              !mdmRestrictions.features.disableUpdateSettings else {
            AppLogger.shared.log("MDM: refusing a server change while the management URL is managed")
            settingsRejectedMessage = "The server for this device is set by your organization."
            showSettingsRejectedAlert = true
            return
        }

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

    /// Fires on every NEVPNStatusDidChange — runs in main app process, even when backgrounded.
    /// Sends the notification from here because UNUserNotificationCenter in NEPacketTunnelProvider
    /// does not reliably deliver notifications (known iOS limitation).
    #if os(iOS)
    private func handleVPNStatusChangeForNotification() {
        let userDefaults = UserDefaults(suiteName: GlobalConstants.userPreferencesSuiteName)
        guard userDefaults?.bool(forKey: GlobalConstants.keyLoginRequired) == true else { return }
        // Only notify when genuinely backgrounded; .inactive is a transitional state (e.g. app
        // opening after a notification tap) — scheduling there fires extra banners via willPresent.
        guard UIApplication.shared.applicationState == .background else { return }

        // Clear the flag immediately so repeated NEVPNStatusDidChange events (VPN passes through
        // several states during disconnect) don't each schedule their own notification.
        userDefaults?.set(false, forKey: GlobalConstants.keyLoginRequired)
        userDefaults?.synchronize()

        AppLogger.shared.log("VPN status changed with loginRequired flag — scheduling notification from main app")
        scheduleLoginRequiredNotification()
    }

    private func scheduleLoginRequiredNotification() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else {
                AppLogger.shared.log("Notifications not authorized, skipping notification")
                return
            }

            // Cancel the delayed best-effort notification scheduled by the extension
            // so that only this one (from the main app process) is delivered.
            center.removePendingNotificationRequests(withIdentifiers: [GlobalConstants.notificationLoginRequired])
            center.removeDeliveredNotifications(withIdentifiers: [GlobalConstants.notificationLoginRequired])

            let content = UNMutableNotificationContent()
            content.title = NSLocalizedString("notification_login_required_title", value: "VPN Disconnected", comment: "")
            content.body = NSLocalizedString("notification_login_required_body", value: "Re-authentication required. Tap to log in and restore your VPN connection.", comment: "")
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: GlobalConstants.notificationLoginRequired,
                content: content,
                trigger: nil
            )
            center.add(request) { error in
                if let error {
                    AppLogger.shared.log("Failed to schedule login notification: \(error.localizedDescription)")
                } else {
                    AppLogger.shared.log("Login notification scheduled from main app process")
                }
            }
        }
    }
    #endif

    /// Checks shared app-group container for login required flag set by the network extension.
    /// Picks up the policy-applied flag the extension sets when an MDM change
    /// forced an engine restart, and tells the user their configuration was
    /// updated. The snapshot is re-read at the same time: the restart means
    /// the policy this process last saw is stale.
    func checkMDMPolicyAppliedFlag() {
        #if os(iOS)
        let userDefaults = UserDefaults(suiteName: GlobalConstants.userPreferencesSuiteName)
        guard userDefaults?.bool(forKey: GlobalConstants.keyMDMPolicyApplied) == true else { return }

        userDefaults?.set(false, forKey: GlobalConstants.keyMDMPolicyApplied)
        userDefaults?.synchronize()

        AppLogger.shared.log("MDM: policy-applied flag detected from extension")
        refreshMDMRestrictions()
        showMDMPolicyAppliedToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            self?.showMDMPolicyAppliedToast = false
        }
        #endif
    }

    /// Shows the authentication UI. Notification was already delivered via NEVPNStatusDidChange observer.
    /// iOS only — tvOS uses IPC via `checkLoginDiagnostics` in TVAuthView.
    func checkLoginRequiredFlag() {
        #if os(iOS)
        let userDefaults = UserDefaults(suiteName: GlobalConstants.userPreferencesSuiteName)
        guard userDefaults?.bool(forKey: GlobalConstants.keyLoginRequired) == true else { return }

        userDefaults?.set(false, forKey: GlobalConstants.keyLoginRequired)
        userDefaults?.synchronize()

        AppLogger.shared.log("Login required flag detected from extension")
        showAuthenticationRequired = true
        connectPressed = false
        updateVPNDisplayState()
        // Temporarily disable On Demand to stop iOS from looping reconnect attempts
        // while the user is not authenticated. It will be re-enabled automatically
        // after a successful connection (see applyExtensionStatus).
        networkExtensionAdapter.setOnDemandEnabled(false)
        #endif
    }

    // MARK: - Debug Bundle

    func uploadDebugBundle() {
        if case .uploading = debugBundleUploadState { return }
        debugBundleUploadState = .uploading
        let anonymize = self.anonymizeDebugBundle

        // Try IPC first (VPN running → live engine state).
        // Fall back to direct call if extension is not reachable (VPN disconnected).
        networkExtensionAdapter.uploadDebugBundle(anonymize: anonymize) { [weak self] result in
            switch result {
            case .success(let key):
                DispatchQueue.main.async { self?.debugBundleUploadState = .done(key: key) }
            case .failure:
                Task.detached(priority: .utility) { [weak self] in
                    let fallbackResult = Self.directDebugBundleUpload(anonymize: anonymize)
                    await MainActor.run { self?.debugBundleUploadState = fallbackResult }
                }
            }
        }
    }

    private static nonisolated func directDebugBundleUpload(anonymize: Bool) -> DebugBundleUploadState {
        #if os(iOS)
        guard let configPath = Preferences.configFile(),
              let statePath = Preferences.stateFile() else {
            return .error(message: "Configuration not available")
        }
        let cacheDir = Preferences.cacheDirectory()
        let logPath = AppLogger.getGoLogFileURL()?.path ?? ""
        guard let client = NetBirdSDKNewClient(configPath, statePath, cacheDir, logPath, Device.getName(), Device.getOsVersion(), Device.getOsName(), nil, nil) else {
            return .error(message: "Failed to initialize client")
        }
        var sdkError: NSError?
        let key = client.debugBundle(anonymize, anonymizeLevel: NetBirdSDKAnonymizeLevelDefault, error: &sdkError)
        if let sdkError {
            return .error(message: sdkError.localizedDescription)
        }
        return .done(key: key)
        #else
        return .error(message: "Not supported on this platform")
        #endif
    }
}
