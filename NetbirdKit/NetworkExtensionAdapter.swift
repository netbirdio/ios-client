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

    @Published var timer : Timer

    @Published var showBrowser = false
    @Published var loginURL : String?

    private let fetchLock = NSLock()
    private var _isFetchingStatus = false
    private var isFetchingStatus: Bool {
        get { fetchLock.lock(); defer { fetchLock.unlock() }; return _isFetchingStatus }
        set { fetchLock.lock(); defer { fetchLock.unlock() }; _isFetchingStatus = newValue }
    }
    
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
