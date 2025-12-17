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
import os
import Combine
import NetBirdSDK

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
    @Published var isSheetExpanded = false
    @Published var presentSideDrawer = false
    @Published var navigateToServerView = false
    
    @Published var extensionState: NEVPNStatus = .disconnected
    @Published var managementStatus: ClientState = .disconnected
    @Published var statusDetailsValid = false
    @Published var extensionStateText = "Disconnected"
    @Published var connectPressed = false
    @Published var disconnectPressed = false
    
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

    /// Preferences are loaded lazily on first access to avoid blocking app startup.
    /// On tvOS, SDK initialization is expensive (generates WireGuard/SSH keys) and
    /// should only happen when actually needed.
    private var _preferences: NetBirdSDKPreferences?
    private var _preferencesLoaded = false
    var preferences: NetBirdSDKPreferences? {
        if !_preferencesLoaded {
            _preferencesLoaded = true
            _preferences = Preferences.newPreferences()
        }
        return _preferences
    }
    var buttonLock = false
    let defaults = UserDefaults.standard
    
    private var cancellables = Set<AnyCancellable>()
    
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
        self.connectPressed = true
        self.buttonLock = true
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
        }
    }
    
    func close() -> Void {
        self.disconnectPressed = true
        DispatchQueue.main.async {
            print("Stopping extension")
            self.buttonLock = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                self.buttonLock = false
            }
            self.networkExtensionAdapter.stop()
        }
    }
    
    func startPollingDetails() {
        networkExtensionAdapter.startTimer { details in
            
            self.checkExtensionState()
            if self.extensionState == .disconnected && self.extensionStateText == "Connected" {
                self.showAuthenticationRequired = true
                self.extensionStateText = "Disconnected"
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
                print("Status: \(details.managementStatus) - Extension: \(self.extensionState) - LoginRequired: \(self.networkExtensionAdapter.isLoginRequired())")
                
                if details.managementStatus != self.managementStatus {
                    self.managementStatus = details.managementStatus
                }
                
                if details.managementStatus == .disconnected && self.extensionState == .connected && self.networkExtensionAdapter.isLoginRequired() {
                    self.networkExtensionAdapter.stop()
                    self.showAuthenticationRequired = true
                }
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

                    // On tvOS, update extensionStateText directly since we don't have CustomLottieView
                    #if os(tvOS)
                    switch status {
                    case .connected:
                        self.extensionStateText = "Connected"
                        self.connectPressed = false
                        // Fetch routes when connected so the Networks counter is accurate on the home screen
                        self.routeViewModel.getRoutes()
                    case .disconnected:
                        self.extensionStateText = "Disconnected"
                        self.disconnectPressed = false
                    case .connecting:
                        self.extensionStateText = "Connecting"
                    case .disconnecting:
                        self.extensionStateText = "Disconnecting"
                    default:
                        break
                    }
                    self.logger.info("checkExtensionState: tvOS - extensionStateText = \(self.extensionStateText)")
                    #endif
                }
            }
        }
    }
    
    func clearDetails() {
        self.ip = ""
        self.fqdn = ""
        defaults.removeObject(forKey: "ip")
        defaults.removeObject(forKey: "fqdn")

        // Clear config from UserDefaults (used on tvOS)
        Preferences.removeConfigFromUserDefaults()

        #if os(tvOS)
        // Also clear extension-local config to prevent stale credentials
        networkExtensionAdapter.clearExtensionConfig()
        #endif
    }
    
    func updatePreSharedKey() {
        guard let preferences = preferences else {
            print("updatePreSharedKey: Preferences not available")
            return
        }
        preferences.setPreSharedKey(presharedKey)
        do {
            try preferences.commit()
            self.close()
            self.presharedKeySecure = true
            self.presentSideDrawer = false
            self.showPreSharedKeyChangedInfo = true
        } catch {
            print("Failed to update preshared key")
        }
    }

    func removePreSharedKey() {
        guard let preferences = preferences else {
            print("removePreSharedKey: Preferences not available")
            return
        }
        presharedKey = ""
        preferences.setPreSharedKey(presharedKey)
        do {
            try preferences.commit()
            self.close()
            self.presharedKeySecure = false
        } catch {
            print("Failed to remove preshared key")
        }
    }

    func loadPreSharedKey() {
        guard let preferences = preferences else {
            print("loadPreSharedKey: Preferences not available")
            return
        }
        self.presharedKey = preferences.getPreSharedKey(nil)
        self.presharedKeySecure = self.presharedKey != ""
    }

    func setRosenpassEnabled(enabled: Bool) {
        guard let preferences = preferences else {
            print("setRosenpassEnabled: Preferences not available")
            return
        }
        preferences.setRosenpassEnabled(enabled)
        do {
            try preferences.commit()
        } catch {
            print("Failed to update rosenpass settings")
        }
    }

    func getRosenpassEnabled() -> Bool {
        guard let preferences = preferences else {
            print("getRosenpassEnabled: Preferences not available")
            return false
        }
        var result = ObjCBool(false)
        do {
            try preferences.getRosenpassEnabled(&result)
        } catch {
            print("Failed to read rosenpass settings")
        }

        return result.boolValue
    }

    func getRosenpassPermissive() -> Bool {
        guard let preferences = preferences else {
            print("getRosenpassPermissive: Preferences not available")
            return false
        }
        var result = ObjCBool(false)
        do {
            try preferences.getRosenpassPermissive(&result)
        } catch {
            print("Failed to read rosenpass permissive settings")
        }

        return result.boolValue
    }

    func setRosenpassPermissive(permissive: Bool) {
        guard let preferences = preferences else {
            print("setRosenpassPermissive: Preferences not available")
            return
        }
        preferences.setRosenpassPermissive(permissive)
        do {
            try preferences.commit()
        } catch {
            print("Failed to update rosenpass permissive settings")
        }
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
}
