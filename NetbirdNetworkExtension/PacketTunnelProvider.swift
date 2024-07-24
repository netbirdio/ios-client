//
//  PacketTunnelProvider.swift
//  NetbirdNetworkExtension
//
//  Created by Pascal Fischer on 06.08.23.
//

import NetworkExtension
import Network
import os
import Firebase
import FirebaseCrashlytics
import FirebaseCore
import FirebasePerformance


class PacketTunnelProvider: NEPacketTunnelProvider {
    
    private lazy var tunnelManager: PacketTunnelProviderSettingsManager = {
        return PacketTunnelProviderSettingsManager(with: self)
    }()
    
    private lazy var adapter: NetBirdAdapter = {
        return NetBirdAdapter(with: self.tunnelManager)
    }()
            
    var pathMonitor: NWPathMonitor?
    let monitorQueue = DispatchQueue(label: "NetworkMonitor")
    var currentNetworkType: NWInterface.InterfaceType?
    
    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let firebaseOptions = FirebaseOptions(contentsOfFile: Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist")!)
        FirebaseApp.configure(options: firebaseOptions!)
        
        if let options = options {
            // For example, handle a specific option
            if let logLevel = options["logLevel"] as? String {
                initializeLogging(loglevel: logLevel)
            }
        }
        
        // Initialize current network type
        currentNetworkType = nil
        
        startMonitoringNetworkChanges()
        
        if adapter.needsLogin() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                completionHandler(NSError(domain: "io.netbird.NetbirdNetworkExtension", code: 1001, userInfo: [NSLocalizedDescriptionKey: "Login required."]))
            }
            return
        }
        
        adapter.start(completionHandler: completionHandler)
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        adapter.stop()
        pathMonitor?.cancel()
        pathMonitor = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            completionHandler()
        }
    }
    
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let completionHandler = completionHandler else { return }
        
        if let string = String(data: messageData, encoding: .utf8) {
            switch string {
            case "Login":
                login(completionHandler: completionHandler)
            case "Status":
                getStatus(completionHandler: completionHandler)
            case "GetRoutes":
                getSelectRoutes(completionHandler: completionHandler)
            case let string where string.hasPrefix("Select-"):
                let id = String(string.dropFirst("Select-".count))
                selectRoute(id: id)
            case let string where string.hasPrefix("Deselect-"):
                let id = String(string.dropFirst("Deselect-".count))
                deselectRoute(id: id)
            default:
                print("unknown message")
            }
        }
    }
    
    func startMonitoringNetworkChanges() {
        pathMonitor = NWPathMonitor()
        pathMonitor?.pathUpdateHandler = { [weak self] path in
            self?.handleNetworkChange(path: path)
        }
        pathMonitor?.start(queue: monitorQueue)
    }

    func handleNetworkChange(path: Network.NWPath) {
        guard path.status == .satisfied else {
            print("No network connection")
            return
        }
        
        let newNetworkType: NWInterface.InterfaceType? = {
            if path.usesInterfaceType(.wifi) {
                return .wifi
            } else if path.usesInterfaceType(.cellular) {
                return .cellular
            } else {
                return nil
            }
        }()
        
        guard let networkType = newNetworkType else {
            print("Connected to other network type")
            return
        }
        
        if currentNetworkType != networkType {
            print("Network type changed to \(networkType)")
            if currentNetworkType != nil {
                restartClient()
            }
            currentNetworkType = networkType
        } else {
            print("Network type remains the same: \(networkType)")
        }
    }
    
    func restartClient() {
        adapter.stop()
        self.adapter.start { error in
            if let error = error {
                print("Error restarting client: \(error.localizedDescription)")
            }
        }
    }
    
    func login(completionHandler: ((Data?) -> Void)) {
        let url = adapter.login()
        let data = url.data(using: .utf8)
        completionHandler(data)
    }
    
    func getStatus(completionHandler: ((Data?) -> Void)) {
        let statusDetailsMessage = adapter.client.getStatusDetails()
        var peerInfoArray: [PeerInfo] = []
        guard let statusDetailsMessage = statusDetailsMessage else {
            print("Did not receive status details")
            return
        }
        for i in 0..<statusDetailsMessage.size() {
            let peer = statusDetailsMessage.get(i)
            let routes = peer!.getRouteDetails()
            var routesArray: [String] = []
            for j in 0..<routes!.size() {
                let route = routes?.get(j)
                routesArray.append(route!.route)
            }
            
            let peerInfo = PeerInfo(ip: peer!.ip, fqdn: peer!.fqdn, localIceCandidateEndpoint:  peer!.localIceCandidateEndpoint, remoteIceCandidateEndpoint: peer!.remoteIceCandidateEndpoint, localIceCandidateType: peer!.localIceCandidateType, remoteIceCandidateType: peer!.remoteIceCandidateType, pubKey: peer!.pubKey, latency: peer!.latency, bytesRx: peer!.bytesRx, bytesTx: peer!.bytesTx, connStatus: peer!.connStatus, connStatusUpdate: peer!.connStatusUpdate, direct: peer!.direct, lastWireguardHandshake: peer!.lastWireguardHandshake, relayed: peer!.relayed, rosenpassEnabled: peer!.relayed, routes: routesArray)
            peerInfoArray.append(peerInfo)
        }
        
        
        let statusDetails = StatusDetails(ip: statusDetailsMessage.getIP(), fqdn: statusDetailsMessage.getFQDN() , managementStatus: self.adapter.clientState, peerInfo: peerInfoArray)
        
        do {
            let data = try PropertyListEncoder().encode(statusDetails)
            completionHandler(data)
            return
        } catch {
            do {
                let defaultStatus = StatusDetails(ip: "", fqdn: "", managementStatus: self.adapter.clientState, peerInfo: [])
                let data = try PropertyListEncoder().encode(defaultStatus)
                completionHandler(data)
                return
            } catch {
                print("Failed to convert default")
            }
            print("Failed to encode status details: \(error.localizedDescription)")
            
        }
    }
    
    func getSelectRoutes(completionHandler: ((Data?) -> Void)) {
        do {
            let routeSelectionDetailsMessage = try adapter.client.getRoutesSelectionDetails()
            
            let routeSelectionInfo: [RoutesSelectionInfo] = (0..<routeSelectionDetailsMessage.size()).compactMap { index in
                guard let route = routeSelectionDetailsMessage.get(index) else { return nil }
                
                let domains: [DomainDetails] = (0..<(route.domains?.size() ?? 0)).compactMap { domainIndex in
                    guard let domain = route.domains?.get(domainIndex) else { return nil }
                    return DomainDetails(domain: domain.domain, resolvedips: domain.resolvedIPs)
                }
                
                return RoutesSelectionInfo(name: route.id_, network: route.network, domains: domains, selected: route.selected)
            }

            let routeSelectionDetails = RoutesSelectionDetails(
                all: routeSelectionDetailsMessage.all,
                append: routeSelectionDetailsMessage.append,
                routeSelectionInfo: routeSelectionInfo
            )
            
            let data = try PropertyListEncoder().encode(routeSelectionDetails)
            completionHandler(data)
        } catch {
            // Handling encoding errors or data fetching errors in one catch block
            print("Error: \(error.localizedDescription)")
            // If an error occurs, send back a default status
            let defaultStatus = RoutesSelectionDetails(all: false, append: false, routeSelectionInfo: [])
            do {
                let data = try PropertyListEncoder().encode(defaultStatus)
                completionHandler(data)
            } catch {
                print("Failed to convert default status: \(error.localizedDescription)")
            }
        }
    }

    
    func selectRoute(id: String) {
        do {
            try adapter.client.selectRoute(id)
        } catch {
            print("Failed to select route")
        }
        
    }
    
    func deselectRoute(id: String) {
        do {
            try adapter.client.deselectRoute(id)
        } catch {
            print("Failed to deselect route")
        }
    }
    
    override func sleep(completionHandler: @escaping () -> Void) {
        // Add code here to get ready to sleep.
        completionHandler()
    }
    
    override func wake() {
        // Add code here to wake up.
    }
    
    func setTunnelSettings(tunnelNetworkSettings: NEPacketTunnelNetworkSettings) {
       setTunnelNetworkSettings(tunnelNetworkSettings) { error in
           if let error = error {
               // Handle Error
               print("error when assigning routes: \(error.localizedDescription)")
               return
           }
           print("Routes set")
       }
    }
}

func initializeLogging(loglevel: String) {
    let fileManager = FileManager.default

    let groupURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: "group.io.netbird.app")
    let logURL = groupURL?.appendingPathComponent("logfile.log")

    var error: NSError?
    var success = false
    
    let logMessage = "Starting new log file from extension" + "\n"
        
    guard let logURLValid = logURL else {
            print("Failed to get the log file URL.")
            return
        }
    
    if fileManager.fileExists(atPath: logURLValid.path) {
        // If the log file already exists, append the new message
        if let fileHandle = try? FileHandle(forWritingTo: logURLValid) {
            do {
                try "".write(to: logURLValid, atomically: true, encoding: .utf8)
            } catch {
                print("Error handling the log file: \(error)")
            }
            if let data = logMessage.data(using: .utf8) {
                fileHandle.write(data)
            }
            fileHandle.closeFile()
        } else {
            print("Failed to open the log file for writing.")
        }
    } else {
        // If the log file doesn't exist, create and write the new message
        do {
            try logMessage.write(to: logURLValid, atomically: true, encoding: .utf8)
        } catch {
            print("Failed to write to the log file: \(error.localizedDescription)")
        }
    }
    
    if let logPath = logURL?.path {
        
        success = NetBirdSDKInitializeLog(loglevel, logPath, &error)
    }
    if !success, let actualError = error {
               print("Failed to initialize log: \(actualError.localizedDescription)")
           }
}
