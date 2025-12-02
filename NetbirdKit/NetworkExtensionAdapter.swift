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

// MARK: - SSO Listener for config initialization
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

    var session : NETunnelProviderSession?
    var vpnManager: NETunnelProviderManager?
    
    #if os(tvOS)
    var extensionID = "io.netbird.app.tv.extension"
    var extensionName = "NetBird TV Network Extension"
    #else
    var extensionID = "io.netbird.app.NetbirdNetworkExtension"
    var extensionName = "NetBird Network Extension"
    #endif
    
    let decoder = PropertyListDecoder()    
    
    @Published var timer : Timer
    
    @Published var showBrowser = false
    @Published var loginURL : String?
    @Published var userCode : String?
    
    init() {
        self.timer = Timer()
        self.timer.invalidate()
        Task {
            do {
                try await self.configureManager()
            } catch {
                print("Failed to configure manager")
            }
        }
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
            await loginIfRequired()
            logger.info("start: loginIfRequired() completed")
        } catch {
            logger.error("start: CAUGHT ERROR - \(error.localizedDescription)")
        }
        logger.info("start: EXIT")
    }

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
        } else {
            logger.info("loginIfRequired: login NOT required, calling startVPNConnection()")
            startVPNConnection()
        }

        logger.info("loginIfRequired: done")
    }

    #if os(tvOS)
    /// Try to initialize the config file from the main app.
    /// This may work on tvOS where the extension doesn't have write access.
    private func initializeConfigFromApp() async {
        let configPath = Preferences.configFile()
        let fileManager = FileManager.default

        // Check if config already exists
        if fileManager.fileExists(atPath: configPath) {
            print("initializeConfigFromApp: Config already exists at \(configPath)")
            return
        }

        print("initializeConfigFromApp: No config found, attempting to create from main app...")

        // Try to create the config using the SDK
        // This creates a new config with WireGuard keys and saves it
        guard let auth = NetBirdSDKNewAuth(configPath, "https://api.netbird.io", nil) else {
            print("initializeConfigFromApp: Failed to create Auth object")
            return
        }

        // Use withCheckedContinuation for proper async/await pattern
        let success: Bool = await withCheckedContinuation { continuation in
            let listener = ConfigSSOListener()
            listener.onResult = { ssoSupported, error in
                if let error = error {
                    print("initializeConfigFromApp: Error - \(error.localizedDescription)")
                    continuation.resume(returning: false)
                } else if ssoSupported != nil {
                    let configExists = fileManager.fileExists(atPath: configPath)
                    print("initializeConfigFromApp: Config exists after save = \(configExists)")
                    continuation.resume(returning: configExists)
                } else {
                    continuation.resume(returning: false)
                }
            }
            auth.saveConfigIfSSOSupported(listener)
        }

        if success {
            print("initializeConfigFromApp: Successfully created config from main app!")
        } else {
            print("initializeConfigFromApp: Failed to create config from main app (extension will try)")
        }
    }
    #endif

    #if os(tvOS)
    /// Ask the Network Extension to initialize config with default management URL
    /// This is required because the app doesn't have permission to write to the App Group container,
    /// but the extension does.
    private func initializeConfigViaExtension() async -> Bool {
        guard let session = self.session else {
            print("initializeConfigViaExtension: No session available")
            return false
        }

        let messageString = "InitializeConfig"
        guard let messageData = messageString.data(using: .utf8) else {
            print("initializeConfigViaExtension: Failed to encode message")
            return false
        }

        return await withCheckedContinuation { continuation in
            do {
                try session.sendProviderMessage(messageData) { response in
                    if let response = response,
                       let responseString = String(data: response, encoding: .utf8) {
                        let success = responseString == "true"
                        print("initializeConfigViaExtension: Extension returned '\(responseString)', success=\(success)")
                        continuation.resume(returning: success)
                    } else {
                        print("initializeConfigViaExtension: No response from extension")
                        continuation.resume(returning: false)
                    }
                }
            } catch {
                print("initializeConfigViaExtension: Failed to send message - \(error)")
                continuation.resume(returning: false)
            }
        }
    }
    #endif
    
    public func isLoginRequired() -> Bool {
        let configPath = Preferences.configFile()
        let statePath = Preferences.stateFile()
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
                print("isLoginRequired: configFile size = \(size) bytes")
            }
        }

        if stateExists {
            if let attrs = try? fileManager.attributesOfItem(atPath: statePath),
               let size = attrs[.size] as? Int64 {
                print("isLoginRequired: stateFile size = \(size) bytes")
            }
        }

        guard let client = NetBirdSDKNewClient(configPath, statePath, Device.getName(), Device.getOsVersion(), Device.getOsName(), nil, nil) else {
            print("isLoginRequired: Failed to initialize client")
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
                print("urlstring: \(urlString)")
                continuation.resume(returning: urlString)
            }
        }
        
        self.loginURL = loginURLString
        self.showBrowser = true
    }

    public func startVPNConnection() {
        logger.info("startVPNConnection: called")
        let logLevel = UserDefaults.standard.string(forKey: "logLevel") ?? "INFO"
        logger.info("startVPNConnection: logLevel = \(logLevel)")
        let options: [String: NSObject] = ["logLevel": logLevel as NSObject]

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
    
    func login(completion: @escaping (String) -> Void) {
        if self.session == nil {
            logger.error("login: No session available for login")
            return
        }

        do {
            // Use LoginTV for tvOS to force device auth flow
            #if os(tvOS)
            let messageString = "LoginTV"
            #else
            let messageString = "Login"
            #endif

            if let messageData = messageString.data(using: .utf8) {
                // Send the message to the network extension
                try self.session!.sendProviderMessage(messageData) { response in
                    if let response = response {
                        if let string = String(data: response, encoding: .utf8) {
                            #if os(tvOS)
                            // For tvOS, response format is "url|userCode"
                            let parts = string.components(separatedBy: "|")
                            if parts.count >= 2 {
                                DispatchQueue.main.async {
                                    self.userCode = parts[1]
                                }
                                completion(parts[0])
                            } else {
                                completion(string)
                            }
                            #else
                            completion(string)
                            #endif
                            return
                        }
                    }
                }
            } else {
                print("Error converting message to Data")
            }
        } catch {
            print("error when performing network extension action")
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
                if let response = response,
                   let responseString = String(data: response, encoding: .utf8) {
                    // Parse diagnostic format: "result|isExecuting|loginRequired|configExists|stateExists|lastResult|lastError"
                    let parts = responseString.components(separatedBy: "|")
                    if parts.count >= 7 {
                        let isComplete = parts[0] == "true"
                        print("checkLoginComplete: result=\(parts[0]), isExecuting=\(parts[1]), loginRequired=\(parts[2]), configExists=\(parts[3]), stateExists=\(parts[4]), lastResult=\(parts[5]), lastError=\(parts[6])")
                        completion(isComplete)
                    } else if parts.count >= 5 {
                        let isComplete = parts[0] == "true"
                        print("checkLoginComplete: result=\(parts[0]), isExecuting=\(parts[1]), loginRequired=\(parts[2]), configExists=\(parts[3]), stateExists=\(parts[4])")
                        completion(isComplete)
                    } else {
                        // Fallback for old format
                        let isComplete = responseString == "true"
                        print("checkLoginComplete: Extension returned '\(responseString)', isComplete=\(isComplete)")
                        completion(isComplete)
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
        guard let session = self.session else {
            let defaultStatus = StatusDetails(ip: "", fqdn: "", managementStatus: .disconnected, peerInfo: [])
            completion(defaultStatus)
            return
        }
        
        let messageString = "Status"
        if let messageData = messageString.data(using: .utf8) {
            do {
                try session.sendProviderMessage(messageData) { response in
                    if let response = response {
                        do {
                            let decodedStatus = try self.decoder.decode(StatusDetails.self, from: response)
                            completion(decodedStatus)
                            return
                        } catch {
                            print("Failed to decode status details.")
                        }
                    } else {
                        let defaultStatus = StatusDetails(ip: "", fqdn: "", managementStatus: .disconnected, peerInfo: [])
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
