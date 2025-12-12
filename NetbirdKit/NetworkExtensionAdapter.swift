//
//  NetworkExtensionAdapter.swift
//  NetBirdiOS
//
//  Created by Pascal Fischer on 02.10.23.
//

import Foundation
import NetworkExtension
import SwiftUI

public class NetworkExtensionAdapter: ObservableObject {
        
    var session : NETunnelProviderSession?
    var vpnManager: NETunnelProviderManager?
    
    var extensionID = "io.netbird.app.NetbirdNetworkExtension"
    var extensionName = "NetBird Network Extension"
    
    let decoder = PropertyListDecoder()
    
    // Battery optimization: Adaptive polling
    // All state variables must be accessed only from pollingQueue to prevent race conditions
    private var currentPollingInterval: TimeInterval = 10.0 // Start with 10 seconds
    private var consecutiveStablePolls: Int = 0
    private var lastStatusHash: Int = 0
    private var isInBackground: Bool = false
    private var lastTimerInterval: TimeInterval = 10.0 // Track last set interval
    private var isPollingActive: Bool = false // Prevents in-flight responses from recreating timer after stopTimer()
    private let pollingQueue = DispatchQueue(label: "com.netbird.polling", qos: .utility)
    
    // Polling intervals (in seconds)
    private let minPollingInterval: TimeInterval = 10.0  // When changes detected
    private let stablePollingInterval: TimeInterval = 20.0  // When stable
    private let backgroundPollingInterval: TimeInterval = 60.0  // In background
    
    @Published var timer : Timer
    
    @Published var showBrowser = false
    @Published var loginURL : String?
    
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
    
    func start() async {
        do {
            try await configureManager()
            print("extension configured")
            await loginIfRequired()
        } catch {
            print("Failed to start extension: \(error)")
        }
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
        if self.isLoginRequired() {
            print("require login")
            
            await performLogin()
        } else {
            startVPNConnection()
        }

        print("will start vpn connection")
    }
    
    public func isLoginRequired() -> Bool {
        guard let client = NetBirdSDKNewClient(Preferences.configFile(), Preferences.stateFile(), Device.getName(), Device.getOsVersion(), Device.getOsName(), nil, nil) else {
            print("Failed to initialize client")
            return true
        }
        return client.isLoginRequired()
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
        print("starting tunnel")
        let logLevel = UserDefaults.standard.string(forKey: "logLevel") ?? "INFO"
        print("Loglevel: " + logLevel)
        let options: [String: NSObject] = ["logLevel": logLevel as NSObject]
        
        do {
            try self.session?.startVPNTunnel(options: options)
            print("VPN Tunnel started.")
        } catch let error {
            print("Failed to start VPN tunnel: \(error)")
        }
    }

    
    func stop() -> Void {
        self.vpnManager?.connection.stopVPNTunnel()
    }
    
    func login(completion: @escaping (String) -> Void) {
        if self.session == nil {
            print("No session available for login")
            return
        }

        do {
            let messageString = "Login"
            if let messageData = messageString.data(using: .utf8) {
                // Send the message to the network extension
                try self.session!.sendProviderMessage(messageData) { response in
                    if let response = response {
                        if let string = String(data: response, encoding: .utf8) {
                            completion(string)
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
                try session.sendProviderMessage(messageData) { [weak self] response in
                    guard let self = self else { return }
                    
                    // Serialize all response handling and state mutations through pollingQueue
                    self.pollingQueue.async { [weak self] in
                        guard let self = self else { return }
                        
                        guard let response = response else {
                            let defaultStatus = StatusDetails(ip: "", fqdn: "", managementStatus: .disconnected, peerInfo: [])
                            completion(defaultStatus)
                            return
                        }
                        
                        do {
                            let decodedStatus = try self.decoder.decode(StatusDetails.self, from: response)
                            
                            // Calculate hash to detect changes
                            let statusHash = self.calculateStatusHash(decodedStatus)
                            let hasChanged = statusHash != self.lastStatusHash
                            
                            if hasChanged {
                                // Status changed - use faster polling
                                self.consecutiveStablePolls = 0
                                self.currentPollingInterval = self.minPollingInterval
                                self.lastStatusHash = statusHash
                                print("Status changed, using fast polling (\(self.currentPollingInterval)s)")
                            } else {
                                // Status stable - gradually increase interval
                                self.consecutiveStablePolls += 1
                                if self.consecutiveStablePolls > 3 {
                                    self.currentPollingInterval = self.stablePollingInterval
                                }
                            }
                            
                            // Restart timer with new interval if needed
                            self.restartTimerIfNeeded(completion: completion)
                            
                            completion(decodedStatus)
                        } catch {
                            print("Failed to decode status details.")
                            let defaultStatus = StatusDetails(ip: "", fqdn: "", managementStatus: .disconnected, peerInfo: [])
                            completion(defaultStatus)
                        }
                    }
                }
            } catch {
                print("Failed to send Provider message")
            }
        } else {
            print("Error converting message to Data")
        }
    }
    
    // Hash includes only core connectivity fields (ip, fqdn, managementStatus, peer.ip, peer.connStatus, peer count)
    // and deliberately omits peer.relayed, peer.direct, peer.connStatusUpdate, and peer.routes.
    // This hash is used to decide polling frequency for battery optimization: only major connectivity
    // changes trigger fast (10s) polling, while secondary/visual-only updates use slower intervals.
    // MainViewModel performs more detailed comparisons for UI updates.
    private func calculateStatusHash(_ status: StatusDetails) -> Int {
        var hasher = Hasher()
        hasher.combine(status.ip)
        hasher.combine(status.fqdn)
        hasher.combine(status.managementStatus)
        hasher.combine(status.peerInfo.count)
        for peer in status.peerInfo {
            hasher.combine(peer.ip)
            hasher.combine(peer.connStatus)
        }
        return hasher.finalize()
    }
    
    private func restartTimerIfNeeded(completion: @escaping (StatusDetails) -> Void) {
        // This function is called from pollingQueue, so we can safely access state variables
        // Bail early if polling was stopped to prevent in-flight responses from recreating timer
        guard isPollingActive else {
            return
        }
        
        // Only restart if interval changed significantly (more than 2 seconds difference)
        let targetInterval = isInBackground ? backgroundPollingInterval : currentPollingInterval
        
        // Check if we need to restart timer
        if abs(lastTimerInterval - targetInterval) > 2.0 {
            lastTimerInterval = targetInterval
            // Capture state values here (on pollingQueue) to avoid deadlock
            let intervalToUse = targetInterval
            let backgroundStateToUse = isInBackground
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if self.timer.isValid {
                    self.timer.invalidate()
                }
                // Pass values directly to avoid pollingQueue.sync call from main thread
                self.startTimer(interval: intervalToUse, backgroundState: backgroundStateToUse, completion: completion)
            }
        }
    }
    
    func startTimer(completion: @escaping (StatusDetails) -> Void) {
        startTimer(interval: nil, backgroundState: nil, completion: completion)
    }
    
    private func startTimer(interval: TimeInterval?, backgroundState: Bool?, completion: @escaping (StatusDetails) -> Void) {
        self.timer.invalidate()
        
        // Initial fetch
        self.fetchData(completion: completion)
        
        // Determine polling interval based on app state
        // If values are provided (from restartTimerIfNeeded), use them to avoid deadlock
        // Otherwise, read from pollingQueue (when called directly from main thread)
        let intervalToUse: TimeInterval
        let backgroundStateToUse: Bool
        
        if let providedInterval = interval, let providedBackgroundState = backgroundState {
            // Values already captured on pollingQueue, use them directly
            intervalToUse = providedInterval
            backgroundStateToUse = providedBackgroundState
            // Update lastTimerInterval and set isPollingActive synchronously to prevent race condition
            // This is safe because we're not in a deadlock situation (values already captured)
            pollingQueue.sync { [weak self] in
                guard let self = self else { return }
                self.lastTimerInterval = providedInterval
                self.isPollingActive = true
            }
        } else {
            // Called directly, must read from pollingQueue (but this is safe as we're not in a deadlock situation)
            var intervalValue: TimeInterval = minPollingInterval
            var backgroundValue: Bool = false
            pollingQueue.sync {
                backgroundValue = isInBackground
                intervalValue = backgroundValue ? backgroundPollingInterval : currentPollingInterval
                lastTimerInterval = intervalValue
                isPollingActive = true
            }
            intervalToUse = intervalValue
            backgroundStateToUse = backgroundValue
        }
        
        // Create timer - must be on main thread for RunLoop
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            self.timer = Timer(timeInterval: intervalToUse, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                // Use background queue for actual network work
                self.pollingQueue.async {
                    self.fetchData(completion: completion)
                }
            }
            
            // Add timer to main RunLoop
            RunLoop.main.add(self.timer, forMode: .common)
            
            print("Started polling with interval: \(intervalToUse)s (background: \(backgroundStateToUse))")
        }
    }
    
    func stopTimer() {
        self.timer.invalidate()
        // Reset state variables and set isPollingActive to false synchronously to prevent race condition
        // Must use sync to ensure flag is set before in-flight fetchData callbacks can check it
        pollingQueue.sync { [weak self] in
            guard let self = self else { return }
            self.consecutiveStablePolls = 0
            self.currentPollingInterval = self.minPollingInterval
            self.isPollingActive = false
        }
    }
    
    func setBackgroundMode(_ inBackground: Bool) {
        // All state mutations must happen on pollingQueue to prevent race conditions
        // Use sync to ensure state is updated before startTimer reads it (fixes timing issue)
        pollingQueue.sync { [weak self] in
            guard let self = self else { return }
            let wasInBackground = self.isInBackground
            self.isInBackground = inBackground
            
            // Restart timer with appropriate interval if state changed
            if wasInBackground != inBackground {
                let interval = inBackground ? self.backgroundPollingInterval : self.currentPollingInterval
                print("App state changed to \(inBackground ? "background" : "foreground"), adjusting polling interval to \(interval)s")
                // Timer will be restarted on next fetchData call via restartTimerIfNeeded
            }
        }
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
