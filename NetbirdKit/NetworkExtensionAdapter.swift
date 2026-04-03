//
//  NetworkExtensionAdapter.swift
//  NetBirdiOS
//
//  Created by Pascal Fischer on 02.10.23.
//

import Foundation
import NetworkExtension
import SwiftUI
import Combine
import NetBirdSDK
import os

// SSO Listener for config initialization
/// Used to check if SSO is supported and save initial config
class ConfigSSOListener: NSObject, NetBirdSDKSSOListenerProtocol {
    var onResult: ((Bool?, Error?) -> Void)?

    func onSuccess(_ ssoSupported: Bool) {
        onResult?(ssoSupported, nil)
    }

    func onError(_ error: Error?) {
        onResult?(nil, error)
    }
}

public class NetworkExtensionAdapter: ObservableObject {

    private let logger = Logger(subsystem: "io.netbird.app", category: "NetworkExtensionAdapter")

    #if os(tvOS)
    static let defaultManagementURL = "https://api.netbird.io"
    #endif

    var session: NETunnelProviderSession?
    var vpnManager: NETunnelProviderManager?

    #if os(tvOS)
    var extensionID = "io.netbird.app.tv.extension"
    var extensionName = "NetBird"
    #else
    var extensionID = "io.netbird.app.NetbirdNetworkExtension"
    var extensionName = "NetBird Network Extension"
    #endif

    let decoder = PropertyListDecoder()

    @Published var timer: Timer

    @Published var showBrowser = false
    @Published var loginURL: String?
    @Published var userCode: String?

    private let fetchLock = NSLock()
    private var _isFetchingStatus = false
    private var isFetchingStatus: Bool {
        get { fetchLock.lock(); defer { fetchLock.unlock() }; return _isFetchingStatus }
        set { fetchLock.lock(); defer { fetchLock.unlock() }; _isFetchingStatus = newValue }
    }

    init() {
        self.timer = Timer()
        self.timer.invalidate()
        // Don't configure manager during init - it's a slow system call that blocks app startup.
        // Instead, configureManager is called lazily when needed (start(), stop(), etc.)
        // This allows the UI to appear immediately on first launch.
    }
    
    deinit {
        self.timer.invalidate()
    }
    
    @MainActor
    func start() async {
        logger.info("start: ENTRY - beginning VPN start sequence")
        do {
            logger.info("start: calling configureManager()...")
            try await configureManager()
            logger.info("start: configureManager() completed, calling loginIfRequired()...")
            #if os(iOS)
            // Restore the config file before login if it was deleted (e.g. after logout).
            // This must happen in the main app — not via IPC — because the extension
            // process may not be running yet when start() is called.
            restoreConfigIfMissing()
            #endif
            await loginIfRequired()
            logger.info("start: loginIfRequired() completed")
        } catch {
            logger.error("start: CAUGHT ERROR - \(error.localizedDescription)")
        }
        logger.info("start: EXIT")
    }

    #if os(iOS)
    /// If the active profile's config file is missing (deleted after logout) but we have
    /// a saved management URL, write a minimal config so the SDK uses the correct server
    /// instead of falling back to the default api.netbird.io.
    private func restoreConfigIfMissing() {
        guard let configPath = Preferences.configFile() else { return }
        guard !FileManager.default.fileExists(atPath: configPath) else { return }

        let profileName = ProfileManager.shared.getActiveProfileName()
        // Prefer the dedicated server URL file (survives logout) over the in-memory cache
        let managementURL = ProfileManager.shared.savedServerURL(for: profileName)
            ?? ProfileConnectionCache().managementURL(for: profileName)
        guard let url = managementURL, !url.isEmpty else {
            logger.info("restoreConfigIfMissing: no saved URL for '\(profileName)', will use default server")
            return
        }

        logger.info("restoreConfigIfMissing: writing minimal config for '\(profileName)' with URL '\(url)'")
        // The Go SDK serializes url.URL as a nested JSON object {Scheme, Host, Path, ...}.
        // Writing ManagementURL as a plain string causes Go's json.Unmarshal to fail silently,
        // leaving ManagementURL nil and falling back to the default api.netbird.io server.
        // We must write the same nested-object format that the Go SDK expects.
        guard let parsedURL = URL(string: url) else {
            logger.error("restoreConfigIfMissing: could not parse URL '\(url)'")
            return
        }
        let scheme = parsedURL.scheme ?? "https"
        // Go's url.URL.Host includes the port (e.g. "my.server.io:443")
        var goHost = parsedURL.host ?? ""
        if let port = parsedURL.port { goHost += ":\(port)" }
        let path = parsedURL.path

        // Escape values for safe embedding in JSON
        func jsonEscape(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
        }

        let minimalConfig = "{\"ManagementURL\":{\"Scheme\":\"\(jsonEscape(scheme))\",\"Host\":\"\(jsonEscape(goHost))\",\"Path\":\"\(jsonEscape(path))\"}}"
        do {
            try minimalConfig.write(toFile: configPath, atomically: true, encoding: .utf8)
            logger.info("restoreConfigIfMissing: config written successfully (Scheme=\(scheme) Host=\(goHost) Path=\(path))")
        } catch {
            logger.error("restoreConfigIfMissing: failed to write config – \(error.localizedDescription)")
        }
    }
    #endif

    private func configureManager() async throws {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        if let manager = managers.first(where: { $0.localizedDescription == self.extensionName }) {
            self.vpnManager = manager
        } else {
            let newManager = createNewManager()
            try await newManager.saveToPreferences()
            self.vpnManager = newManager
        }
        self.vpnManager?.isEnabled = true
        try await self.vpnManager?.saveToPreferences()
        try await self.vpnManager?.loadFromPreferences()
        self.session = self.vpnManager?.connection as? NETunnelProviderSession
    }

    /// Loads an existing VPN manager from preferences and returns the current connection state.
    /// This is used on app startup to establish the session for status polling and get the
    /// initial connection state, without triggering VPN configuration or starting a connection.
    /// Returns the current VPN connection status if a manager was found, nil otherwise.
    @MainActor
    public func loadCurrentConnectionState() async -> NEVPNStatus? {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            if let manager = managers.first(where: { $0.localizedDescription == self.extensionName }) {
                self.vpnManager = manager
                self.session = manager.connection as? NETunnelProviderSession
                let status = manager.connection.status
                logger.info("loadCurrentConnectionState: Found existing manager, session established, status: \(status.rawValue)")
                return status
            } else {
                logger.info("loadCurrentConnectionState: No existing manager found")
                return nil
            }
        } catch {
            logger.error("loadCurrentConnectionState: Error loading managers: \(error.localizedDescription)")
            return nil
        }
    }

    private func createNewManager() -> NETunnelProviderManager {
        let tunnelProviderProtocol = NETunnelProviderProtocol()
        tunnelProviderProtocol.providerBundleIdentifier = self.extensionID
        tunnelProviderProtocol.serverAddress = "multiple endpoints"
        
        let newManager = NETunnelProviderManager()
        newManager.protocolConfiguration = tunnelProviderProtocol
        newManager.localizedDescription = self.extensionName
        newManager.isEnabled = true

        return newManager
    }
    


    public func loginIfRequired() async {
        logger.info("loginIfRequired: starting...")

        #if os(tvOS)
        // On tvOS, try to initialize config from the main app first.
        // This is needed because the Network Extension may not have write access
        // to the App Group container on tvOS.
        logger.info("loginIfRequired: tvOS - calling initializeConfigFromApp()")
        await initializeConfigFromApp()
        #endif

        let needsLogin = self.isLoginRequired()
        logger.info("loginIfRequired: isLoginRequired() returned \(needsLogin)")

        if needsLogin {
            logger.info("loginIfRequired: login required, calling performLogin()")
            // Note: For tvOS, config initialization happens in the extension's startTunnel
            // before the needsLogin check. The extension has permission to write to App Group.
            await performLogin()

            #if os(iOS)
            // If performLogin() didn't open the browser, the IPC failed because the extension
            // is not running. Start the VPN connection anyway so the extension process starts,
            // detects login required, signals the main app via UserDefaults, and stays alive
            // long enough for the user to press Connect from the auth alert (which will retry
            // IPC to a still-alive extension and succeed).
            if !self.showBrowser {
                logger.info("loginIfRequired: IPC failed (extension not running), starting VPN to launch extension")
                startVPNConnection()
            }
            #endif
        } else {
            logger.info("loginIfRequired: login NOT required, calling startVPNConnection()")
            startVPNConnection()
        }

        logger.info("loginIfRequired: done")
    }

    #if os(tvOS)
    /// Try to initialize the config file from the main app.
    /// On tvOS, shared UserDefaults doesn't work, so we send config via IPC.
    /// Settings (Rosenpass, PreSharedKey) are already stored in the config JSON.
    private func initializeConfigFromApp() async {
        // Check if config exists in main app's UserDefaults
        // Note: Shared UserDefaults doesn't work on tvOS between app and extension,
        // but we can still use it to store config in the main app
        if let configJSON = Preferences.loadConfigFromUserDefaults(), !configJSON.isEmpty {
            logger.info("initializeConfigFromApp: Config exists in UserDefaults (\(configJSON.count) chars), sending to extension via IPC")

            // Check if session exists for IPC
            if self.session == nil {
                logger.error("initializeConfigFromApp: session is nil! IPC will fail. Config won't reach extension.")
            }

            // Send config to extension via IPC (settings are already in the JSON)
            await sendConfigToExtensionAsync(configJSON)

            // Also send the management URL separately — the config JSON from Go SDK
            // serializes ManagementURL as a nested object, not a plain string,
            // so regex extraction in the extension fails.
            if let managementURL = Preferences.loadManagementURL() {
                logger.info("initializeConfigFromApp: Sending management URL separately: \(managementURL, privacy: .public)")
                await sendManagementURLToExtensionAsync(managementURL)
            } else {
                logger.warning("initializeConfigFromApp: No separate management URL saved")
            }
            return
        }

        guard let configPath = Preferences.configFile() else {
            logger.error("initializeConfigFromApp: App group container unavailable")
            return
        }
        let fileManager = FileManager.default

        // Check if config already exists as a file (unlikely on tvOS but check anyway)
        if fileManager.fileExists(atPath: configPath) {
            logger.info("initializeConfigFromApp: Config already exists at \(configPath)")
            return
        }

        logger.info("initializeConfigFromApp: No config found, user needs to configure server first")
        // Don't automatically create config with default URL - user should go through ServerView
    }

    /// Async wrapper for sendConfigToExtension
    private func sendConfigToExtensionAsync(_ configJSON: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sendConfigToExtension(configJSON) { [weak self] success in
                self?.logger.info("sendConfigToExtensionAsync: IPC result = \(success)")
                continuation.resume()
            }
        }
    }

    /// Send the management URL to the extension separately via IPC.
    /// This is needed because the Go SDK config JSON serializes ManagementURL
    /// as a nested object, making regex extraction unreliable.
    private func sendManagementURLToExtensionAsync(_ url: String) async {
        guard let session = self.session else {
            logger.warning("sendManagementURLToExtensionAsync: No session available")
            return
        }

        let messageString = "SetManagementURL:\(url)"
        guard let messageData = messageString.data(using: .utf8) else { return }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            do {
                try session.sendProviderMessage(messageData) { [weak self] response in
                    let success = response.flatMap { String(data: $0, encoding: .utf8) } == "true"
                    self?.logger.info("sendManagementURLToExtensionAsync: result = \(success)")
                    continuation.resume()
                }
            } catch {
                self.logger.error("sendManagementURLToExtensionAsync: Failed: \(error.localizedDescription)")
                continuation.resume()
            }
        }
    }
    #endif
    
    public func isLoginRequired() -> Bool {
        guard let configPath = Preferences.configFile(), let statePath = Preferences.stateFile() else {
            logger.error("isLoginRequired: App group container unavailable - assuming login required")
            return true
        }
        logger.info("isLoginRequired: checking config at \(configPath), state at \(statePath)")

        // Debug: Check if files exist and their sizes
        let fileManager = FileManager.default
        let configExists = fileManager.fileExists(atPath: configPath)
        let stateExists = fileManager.fileExists(atPath: statePath)
        logger.info("isLoginRequired: configFile exists = \(configExists), stateFile exists = \(stateExists)")

        #if os(tvOS)
        // On tvOS, the app doesn't have permission to write to App Group container.
        // File writes are blocked, so we check UserDefaults instead.
        // Config is saved to UserDefaults after successful login.
        let hasConfigInUserDefaults = Preferences.hasConfigInUserDefaults()
        logger.info("isLoginRequired: tvOS - hasConfigInUserDefaults = \(hasConfigInUserDefaults)")

        if !hasConfigInUserDefaults {
            // No config in UserDefaults - user definitely needs to login
            logger.info("isLoginRequired: tvOS - no config in UserDefaults, login required")
            return true
        }

        // Config exists - but we need to verify with the management server
        // that the session is still valid (tokens can expire)
        logger.info("isLoginRequired: tvOS - config found, checking with management server...")

        // Create a Client and load config from UserDefaults
        guard let client = NetBirdSDKNewClient("", "", Device.getName(), Device.getOsVersion(), Device.getOsName(), nil, nil) else {
            logger.error("isLoginRequired: tvOS - failed to create SDK client")
            return true
        }

        // Load the config from UserDefaults into the client
        if let configJSON = Preferences.loadConfigFromUserDefaults() {
            do {
                try client.setConfigFromJSON(configJSON)
                logger.info("isLoginRequired: tvOS - loaded config from UserDefaults into client")
            } catch {
                logger.error("isLoginRequired: tvOS - failed to load config: \(error.localizedDescription)")
                return true
            }
        } else {
            logger.error("isLoginRequired: tvOS - no config JSON in UserDefaults")
            return true
        }

        // Now check with the management server
        let result = client.isLoginRequired()
        logger.info("isLoginRequired: tvOS - SDK returned \(result)")
        return result
        #else
        if configExists {
            if let attrs = try? fileManager.attributesOfItem(atPath: configPath),
               let size = attrs[.size] as? Int64 {
                logger.debug("isLoginRequired: configFile size = \(size) bytes")
            }
        }

        if stateExists {
            if let attrs = try? fileManager.attributesOfItem(atPath: statePath),
               let size = attrs[.size] as? Int64 {
                logger.debug("isLoginRequired: stateFile size = \(size) bytes")
            }
        }

        guard let client = NetBirdSDKNewClient(configPath, statePath, Device.getName(), Device.getOsVersion(), Device.getOsName(), nil, nil) else {
            logger.debug("isLoginRequired: Failed to initialize client")
            return true
        }

        let result = client.isLoginRequired()
        print("isLoginRequired: SDK returned \(result)")
        return result
        #endif
    }

    class ObserverBox {
        var observer: NSObjectProtocol?
    }

    private func performLogin() async {
        let loginURLString = await withCheckedContinuation { continuation in
            self.login { urlString in
                continuation.resume(returning: urlString)
            }
        }

        guard let url = loginURLString, !url.isEmpty else {
            logger.error("performLogin: no login URL received from extension, aborting")
            return
        }

        self.loginURL = url
        self.showBrowser = true
    }

    public func startVPNConnection() {
        logger.info("startVPNConnection: called")
        let logLevel = UserDefaults.standard.string(forKey: "logLevel") ?? "INFO"
        logger.info("startVPNConnection: logLevel = \(logLevel)")
        var options: [String: NSObject] = ["logLevel": logLevel as NSObject]
        #if os(iOS)
        // Pass active profile paths so the extension can reinitialize the adapter
        // if the profile changed while the extension process was still alive.
        if let configPath = Preferences.configFile() {
            options["configPath"] = configPath as NSObject
        }
        if let statePath = Preferences.stateFile() {
            options["statePath"] = statePath as NSObject
        }
        logger.info("startVPNConnection: configPath=\(Preferences.configFile() ?? "nil")")
        #endif

        guard let session = self.session else {
            logger.error("startVPNConnection: ERROR - session is nil!")
            return
        }

        logger.info("startVPNConnection: session exists, calling startVPNTunnel...")
        do {
            try session.startVPNTunnel(options: options)
            logger.info("startVPNConnection: startVPNTunnel() returned successfully")
        } catch let error {
            logger.error("startVPNConnection: ERROR - startVPNTunnel failed: \(error.localizedDescription)")
        }
    }

    
    func stop() -> Void {
        self.vpnManager?.connection.stopVPNTunnel()
    }

    /// Updates the VPN On Demand configuration on the current manager.
    /// When enabled, iOS will automatically reconnect the VPN after network changes or reboot.
    /// Should only be enabled when the user is logged in to avoid reconnect loops.
    func setOnDemandEnabled(_ enabled: Bool) {
        guard let manager = self.vpnManager else {
            logger.warning("setOnDemandEnabled: No VPN manager available")
            return
        }

        if enabled {
            let defaults = UserDefaults(suiteName: GlobalConstants.userPreferencesSuiteName)
            let loginRequired = defaults?.bool(forKey: GlobalConstants.keyLoginRequired) ?? true
            if loginRequired {
                logger.warning("setOnDemandEnabled: Refusing to enable On Demand — user is not logged in")
                return
            }
        }

        if enabled {
            // Build rules from saved settings
            let rules = buildOnDemandRules()
            if rules.isEmpty {
                // All policies are "Do Nothing" — don't interfere with connection state
                let ignoreRule = NEOnDemandRuleIgnore()
                ignoreRule.interfaceTypeMatch = .any
                manager.onDemandRules = [ignoreRule]
            } else {
                manager.onDemandRules = rules
            }
        } else {
            manager.onDemandRules = []
        }
        manager.isOnDemandEnabled = enabled

        manager.saveToPreferences { error in
            if let error = error {
                self.logger.error("setOnDemandEnabled: Failed to save preferences: \(error.localizedDescription)")
            } else {
                self.logger.info("setOnDemandEnabled: On Demand \(enabled ? "enabled" : "disabled") successfully")
            }
        }
    }

    /// Applies granular On Demand rules based on Wi-Fi/Cellular policies and network lists.
    func applyOnDemandRules(wifiPolicy: WiFiOnDemandPolicy, cellularPolicy: CellularOnDemandPolicy, wifiNetworks: [String]) {
        guard let manager = self.vpnManager else {
            logger.warning("applyOnDemandRules: No VPN manager available")
            return
        }

        let rules = buildOnDemandRulesFrom(wifiPolicy: wifiPolicy, cellularPolicy: cellularPolicy, wifiNetworks: wifiNetworks)
        if rules.isEmpty {
            // All policies are "Do Nothing" — don't interfere with connection state
            let ignoreRule = NEOnDemandRuleIgnore()
            ignoreRule.interfaceTypeMatch = .any
            manager.onDemandRules = [ignoreRule]
        } else {
            manager.onDemandRules = rules
        }

        manager.saveToPreferences { error in
            if let error = error {
                self.logger.error("applyOnDemandRules: Failed to save preferences: \(error.localizedDescription)")
            } else {
                self.logger.info("applyOnDemandRules: Rules applied successfully")
            }
        }
    }

    /// Builds NEOnDemandRule array from persisted UserDefaults settings.
    private func buildOnDemandRules() -> [NEOnDemandRule] {
        let userDefaults = UserDefaults(suiteName: GlobalConstants.userPreferencesSuiteName)
        let wifiRaw = userDefaults?.string(forKey: GlobalConstants.keyOnDemandWiFiPolicy) ?? WiFiOnDemandPolicy.always.rawValue
        let cellularRaw = userDefaults?.string(forKey: GlobalConstants.keyOnDemandCellularPolicy) ?? CellularOnDemandPolicy.always.rawValue
        let wifiPolicy = WiFiOnDemandPolicy(rawValue: wifiRaw) ?? .always
        let cellularPolicy = CellularOnDemandPolicy(rawValue: cellularRaw) ?? .always
        let wifiNetworks = userDefaults?.stringArray(forKey: GlobalConstants.keyOnDemandWiFiNetworks) ?? []
        return buildOnDemandRulesFrom(wifiPolicy: wifiPolicy, cellularPolicy: cellularPolicy, wifiNetworks: wifiNetworks)
    }

    /// Converts policy enums into NEOnDemandRule objects.
    private func buildOnDemandRulesFrom(wifiPolicy: WiFiOnDemandPolicy, cellularPolicy: CellularOnDemandPolicy, wifiNetworks: [String]) -> [NEOnDemandRule] {
        var rules: [NEOnDemandRule] = []

        // Wi-Fi rules
        switch wifiPolicy {
        case .always:
            let rule = NEOnDemandRuleConnect()
            rule.interfaceTypeMatch = .wiFi
            rules.append(rule)
        case .onlyOn:
            if !wifiNetworks.isEmpty {
                let connectRule = NEOnDemandRuleConnect()
                connectRule.interfaceTypeMatch = .wiFi
                connectRule.ssidMatch = wifiNetworks
                rules.append(connectRule)
            }
            // Disconnect on all other Wi-Fi networks (or all Wi-Fi if list is empty)
            let disconnectRule = NEOnDemandRuleDisconnect()
            disconnectRule.interfaceTypeMatch = .wiFi
            rules.append(disconnectRule)
        case .exceptOn:
            if !wifiNetworks.isEmpty {
                let disconnectRule = NEOnDemandRuleDisconnect()
                disconnectRule.interfaceTypeMatch = .wiFi
                disconnectRule.ssidMatch = wifiNetworks
                rules.append(disconnectRule)
            }
            let connectRule = NEOnDemandRuleConnect()
            connectRule.interfaceTypeMatch = .wiFi
            rules.append(connectRule)
        case .never:
            let rule = NEOnDemandRuleDisconnect()
            rule.interfaceTypeMatch = .wiFi
            rules.append(rule)
        case .doNothing:
            break
        }

        // Cellular rules (cellular is not available on tvOS)
        #if !os(tvOS)
        switch cellularPolicy {
        case .always:
            let rule = NEOnDemandRuleConnect()
            rule.interfaceTypeMatch = .cellular
            rules.append(rule)
        case .never:
            let rule = NEOnDemandRuleDisconnect()
            rule.interfaceTypeMatch = .cellular
            rules.append(rule)
        case .doNothing:
            break
        }
        #endif

        return rules
    }

    /// Returns the current On Demand enabled state from the VPN manager.
    var isOnDemandEnabled: Bool {
        return vpnManager?.isOnDemandEnabled ?? false
    }

    func login(completion: @escaping (String?) -> Void) {
        guard let session = self.session else {
            logger.error("login: No session available for login")
            completion(nil)
            return
        }

        do {
            // Use LoginTV for tvOS to force device auth flow
            #if os(tvOS)
            let messageString = "LoginTV"
            #else
            // Include active profile paths so the extension can reinitialize
            // its adapter for the correct profile before performing login.
            // Also include the cached management URL so the extension can restore
            // a missing config (e.g. after logout) and use the correct server.
            // Format: "Login:<configPath>|<statePath>[|<managementURL>]"
            var messageString = "Login"
            if let configPath = Preferences.configFile(), let statePath = Preferences.stateFile() {
                messageString = "Login:\(configPath)|\(statePath)"
                let profileName = ProfileManager.shared.getActiveProfileName()
                if let cachedURL = ProfileConnectionCache().managementURL(for: profileName),
                   !cachedURL.isEmpty {
                    messageString += "|\(cachedURL)"
                }
            }
            #endif

            if let messageData = messageString.data(using: .utf8) {
                // Send the message to the network extension
                try session.sendProviderMessage(messageData) { response in
                    guard let response = response else {
                        self.logger.error("login: No response from extension")
                        completion(nil)
                        return
                    }
                    #if os(tvOS)
                    // For tvOS, decode DeviceAuthResponse struct
                    do {
                        let authResponse = try self.decoder.decode(DeviceAuthResponse.self, from: response)
                        DispatchQueue.main.async {
                            self.userCode = authResponse.userCode
                        }
                        completion(authResponse.url)
                    } catch {
                        print("login: Failed to decode DeviceAuthResponse - \(error)")
                        // Fallback to plain string for backwards compatibility
                        completion(String(data: response, encoding: .utf8))
                    }
                    #else
                    completion(String(data: response, encoding: .utf8))
                    #endif
                }
            } else {
                print("Error converting message to Data")
                completion(nil)
            }
        } catch {
            print("error when performing network extension action")
            completion(nil)
        }
    }

    /// Check if login is complete by asking the Network Extension directly
    /// This is more reliable than isLoginRequired() because it queries the same SDK client
    /// that is actually performing the login
    func checkLoginComplete(completion: @escaping (Bool) -> Void) {
        guard let session = self.session else {
            logger.error("checkLoginComplete: No session available")
            completion(false)
            return
        }

        let messageString = "IsLoginComplete"
        guard let messageData = messageString.data(using: .utf8) else {
            print("checkLoginComplete: Failed to encode message")
            completion(false)
            return
        }

        do {
            try session.sendProviderMessage(messageData) { response in
                if let response = response {
                    do {
                        let diagnostic = try self.decoder.decode(LoginDiagnostics.self, from: response)
                        print("checkLoginComplete: result=\(diagnostic.isComplete), isExecuting=\(diagnostic.isExecuting), loginRequired=\(diagnostic.loginRequired), configExists=\(diagnostic.configExists), stateExists=\(diagnostic.stateExists), lastResult=\(diagnostic.lastResult), lastError=\(diagnostic.lastError)")
                        completion(diagnostic.isComplete)
                    } catch {
                        print("checkLoginComplete: Failed to decode LoginDiagnostics - \(error)")
                        completion(false)
                    }
                } else {
                    print("checkLoginComplete: No response from extension")
                    completion(false)
                }
            }
        } catch {
            print("checkLoginComplete: Failed to send message - \(error)")
            completion(false)
        }
    }

    /// Check if there's a login error from the extension
    /// Returns the error message via completion handler, or nil if no error
    func checkLoginError(completion: @escaping (String?) -> Void) {
        guard let session = self.session else {
            completion(nil)
            return
        }

        let messageString = "IsLoginComplete"
        guard let messageData = messageString.data(using: .utf8) else {
            completion(nil)
            return
        }

        do {
            try session.sendProviderMessage(messageData) { response in
                if let response = response {
                    do {
                        let diagnostic = try self.decoder.decode(LoginDiagnostics.self, from: response)
                        // Only report error if lastResult is "error" and there's an actual error message
                        if diagnostic.lastResult == "error" && !diagnostic.lastError.isEmpty {
                            // Make the error message more user-friendly
                            var friendlyError = diagnostic.lastError
                            if diagnostic.lastError.contains("no peer auth method provided") {
                                friendlyError = "This server doesn't support device code authentication. Please use a setup key instead."
                            } else if diagnostic.lastError.contains("expired") || diagnostic.lastError.contains("token") {
                                friendlyError = "The device code has expired. Please try again."
                            } else if diagnostic.lastError.contains("denied") || diagnostic.lastError.contains("rejected") {
                                friendlyError = "Authentication was denied. Please try again."
                            }
                            completion(friendlyError)
                            return
                        }
                        completion(nil)
                    } catch {
                        print("checkLoginError: Failed to decode LoginDiagnostics - \(error)")
                        completion(nil)
                    }
                } else {
                    completion(nil)
                }
            }
        } catch {
            completion(nil)
        }
    }

    func getRoutes(completion: @escaping (RoutesSelectionDetails) -> Void) {
        guard let session = self.session else {
            let defaultStatus = RoutesSelectionDetails(all: false, append: false, routeSelectionInfo: [])
            completion(defaultStatus)
            return
        }
        
        let messageString = "GetRoutes"
        if let messageData = messageString.data(using: .utf8) {
            do {
                try session.sendProviderMessage(messageData) { response in
                    if let response = response {
                        do {
                            let decodedStatus = try self.decoder.decode(RoutesSelectionDetails.self, from: response)
                            completion(decodedStatus)
                            return
                        } catch {
                            print("Failed to decode route selection details.")
                        }
                    } else {
                        let defaultStatus = RoutesSelectionDetails(all: false, append: false, routeSelectionInfo: [])
                        completion(defaultStatus)
                        return
                    }
                }
            } catch {
                print("Failed to send Provider message")
            }
        } else {
            print("Error converting message to Data")
        }
    }

    func selectRoutes(id: String, completion: @escaping (RoutesSelectionDetails) -> Void) {
        guard let session = self.session else {
            return
        }

        let messageString = "Select-\(id)"
        if let messageData = messageString.data(using: .utf8) {
            do {
                try session.sendProviderMessage(messageData) { response in
                    let routes = RoutesSelectionDetails(all: false, append: false, routeSelectionInfo: [])
                    completion(routes)
                }
            } catch {
                print("Failed to send Provider message")
            }
        } else {
            print("Error converting message to Data")
        }
    }

    func deselectRoutes(id: String, completion: @escaping (RoutesSelectionDetails) -> Void) {
        guard let session = self.session else {
            return
        }

        let messageString = "Deselect-\(id)"
        if let messageData = messageString.data(using: .utf8) {
            do {
                try session.sendProviderMessage(messageData) { response in
                    let routes = RoutesSelectionDetails(all: false, append: false, routeSelectionInfo: [])
                    completion(routes)
                }
            } catch {
                print("Failed to send Provider message")
            }
        } else {
            print("Error converting message to Data")
        }
    }
    
    func fetchData(completion: @escaping (StatusDetails) -> Void) {
        guard !isFetchingStatus else {
            return
        }

        let defaultStatus = StatusDetails(ip: "", fqdn: "", managementStatus: .disconnected, peerInfo: [])
        
        guard let session = self.session else {
            completion(defaultStatus)
            return
        }

        isFetchingStatus = true
        var hasCompleted = false
        let completionLock = NSLock()
        
        // This is to make sure completion is called only once
        let safeCompletion: (StatusDetails) -> Void = { [weak self] status in
            completionLock.lock()
            defer { completionLock.unlock() }
            
            guard !hasCompleted else { return }
            hasCompleted = true
            
            self?.isFetchingStatus = false
            completion(status)
        }
        
        // Timeout after 10 seconds to reset fetching status to false
        let timeoutWorkItem = DispatchWorkItem {
            AppLogger.shared.log("fetchData timed out")
            safeCompletion(defaultStatus)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeoutWorkItem)
    
        let messageString = "Status"
        
        if let messageData = messageString.data(using: .utf8) {
            do {
                try session.sendProviderMessage(messageData) { [weak self] response in
                    timeoutWorkItem.cancel()
                    
                    guard let response = response else {
                        safeCompletion(defaultStatus)
                        return
                    }
                    
                    do {
                        let decodedStatus = try self?.decoder.decode(StatusDetails.self, from: response)
                        safeCompletion(decodedStatus ?? defaultStatus)
                    } catch {
                        AppLogger.shared.log("Failed to decode status details: \(error)")
                        safeCompletion(defaultStatus)
                    }
                }
            } catch {
                timeoutWorkItem.cancel()
                AppLogger.shared.log("Failed to send Provider message")
                safeCompletion(defaultStatus)
            }
        } else {
            timeoutWorkItem.cancel()
            AppLogger.shared.log("Error converting message to Data")
            safeCompletion(defaultStatus)
        }
    }
    
    func startTimer(completion: @escaping (StatusDetails) -> Void) {
        self.timer.invalidate()
        self.fetchData(completion: completion)
        self.timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true, block: { _ in
            self.fetchData(completion: completion)
        })
    }
    
    func stopTimer() {
        self.timer.invalidate()
    }

    #if os(tvOS)
    /// Send config JSON to the Network Extension via IPC
    /// On tvOS, shared UserDefaults doesn't work between app and extension,
    /// so we transfer config directly via IPC
    func sendConfigToExtension(_ configJSON: String, completion: ((Bool) -> Void)? = nil) {
        guard let session = self.session else {
            logger.warning("sendConfigToExtension: No session available")
            completion?(false)
            return
        }

        let messageString = "SetConfig:\(configJSON)"
        guard let messageData = messageString.data(using: .utf8) else {
            logger.error("sendConfigToExtension: Failed to convert message to Data")
            completion?(false)
            return
        }

        do {
            try session.sendProviderMessage(messageData) { response in
                if let response = response,
                   let responseString = String(data: response, encoding: .utf8),
                   responseString == "true" {
                    self.logger.info("sendConfigToExtension: Config sent successfully")
                    completion?(true)
                } else {
                    self.logger.warning("sendConfigToExtension: Extension did not confirm receipt")
                    completion?(false)
                }
            }
        } catch {
            logger.error("sendConfigToExtension: Failed to send message: \(error.localizedDescription)")
            completion?(false)
        }
    }

    /// Clear extension-local config on logout
    /// This ensures the extension doesn't have stale credentials after logout
    func clearExtensionConfig(completion: ((Bool) -> Void)? = nil) {
        guard let session = self.session else {
            logger.warning("clearExtensionConfig: No session available")
            completion?(false)
            return
        }

        let messageString = "ClearConfig"
        guard let messageData = messageString.data(using: .utf8) else {
            logger.error("clearExtensionConfig: Failed to convert message to Data")
            completion?(false)
            return
        }

        do {
            try session.sendProviderMessage(messageData) { response in
                if let response = response,
                   let responseString = String(data: response, encoding: .utf8),
                   responseString == "true" {
                    self.logger.info("clearExtensionConfig: Extension config cleared successfully")
                    completion?(true)
                } else {
                    self.logger.warning("clearExtensionConfig: Extension did not confirm clearing")
                    completion?(false)
                }
            }
        } catch {
            logger.error("clearExtensionConfig: Failed to send message: \(error.localizedDescription)")
            completion?(false)
        }
    }
    #endif

    func getExtensionStatus(completion: @escaping (NEVPNStatus) -> Void) {
        Task {
            do {
                let managers = try await NETunnelProviderManager.loadAllFromPreferences()
                if let manager = managers.first(where: { $0.localizedDescription == self.extensionName }) {
                    completion(manager.connection.status)
                }
            } catch {
                print("Error loading from preferences: \(error)")
            }
        }
    }
}
