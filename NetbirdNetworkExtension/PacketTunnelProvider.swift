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
import UserNotifications


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

    /// Tracks if engine was stopped due to network unavailability (e.g., airplane mode)
    var wasStoppedDueToNoNetwork = false

    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        if let googleServicePlistPath = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
           let firebaseOptions = FirebaseOptions(contentsOfFile: googleServicePlistPath) {
            FirebaseApp.configure(options: firebaseOptions)
        }

        if let options = options, let logLevel = options["logLevel"] as? String {
            initializeLogging(loglevel: logLevel)
        }

        currentNetworkType = nil
        wasStoppedDueToNoNetwork = false
        startMonitoringNetworkChanges()

        if adapter.needsLogin() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                let error = NSError(
                    domain: "io.netbird.NetbirdNetworkExtension",
                    code: 1001,
                    userInfo: [NSLocalizedDescriptionKey: "Login required."]
                )
                completionHandler(error)
            }
            return
        }

        adapter.start(completionHandler: completionHandler)
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        wasStoppedDueToNoNetwork = false
        adapter.stop()
        guard let pathMonitor = self.pathMonitor else {
            print("pathMonitor is nil; nothing to cancel.")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                completionHandler()
            }
            return
        }
        pathMonitor.cancel()
        self.pathMonitor = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            completionHandler()
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let completionHandler = completionHandler,
              let string = String(data: messageData, encoding: .utf8) else {
            return
        }

        switch string {
        case "Login":
            login(completionHandler: completionHandler)
        case "Status":
            getStatus(completionHandler: completionHandler)
        case "GetRoutes":
            getSelectRoutes(completionHandler: completionHandler)
        case let s where s.hasPrefix("Select-"):
            let id = String(s.dropFirst("Select-".count))
            selectRoute(id: id)
        case let s where s.hasPrefix("Deselect-"):
            let id = String(s.dropFirst("Deselect-".count))
            deselectRoute(id: id)
        default:
            print("Unknown message: \(string)")
        }
    }

    func startMonitoringNetworkChanges() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            self?.handleNetworkChange(path: path)
        }
        monitor.start(queue: monitorQueue)
    
        pathMonitor = monitor
    }

    func handleNetworkChange(path: Network.NWPath) {
        if path.status != .satisfied {
            AppLogger.shared.log("No network connection detected")

            // Stop engine if running and not already stopped for this reason
            if !wasStoppedDueToNoNetwork && adapter.clientState != .disconnected {
                AppLogger.shared.log("Stopping engine due to no network (airplane mode?)")
                wasStoppedDueToNoNetwork = true
                currentNetworkType = nil
                adapter.isRestarting = true
                adapter.stop { [weak self] in
                    self?.adapter.isRestarting = false
                    AppLogger.shared.log("Engine stopped due to no network")
                }
            }
            return
        }

        // Network is back - check if we need to restart
        if wasStoppedDueToNoNetwork {
            AppLogger.shared.log("Network restored after unavailability")
            wasStoppedDueToNoNetwork = false

            if adapter.needsLogin() {
                AppLogger.shared.log("Login required after network restore - sending notification")
                sendLoginRequiredNotification()
                // Leave app in stopped state - user needs to open app to login
            } else {
                AppLogger.shared.log("Restarting engine after network restore")
                adapter.isRestarting = true
                adapter.start { [weak self] error in
                    self?.adapter.isRestarting = false
                    if let error = error {
                        AppLogger.shared.log("Restart after network restore failed: \(error.localizedDescription)")
                    } else {
                        AppLogger.shared.log("Engine restarted after network restore")
                    }
                }
            }
            return
        }

        // Handle wifi <-> cellular transitions
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
            AppLogger.shared.log("Connected to an unsupported network type")
            return
        }

        if currentNetworkType != networkType {
            AppLogger.shared.log("Network type changed: \(String(describing: currentNetworkType)) -> \(networkType)")
            if currentNetworkType != nil {
                restartClient()
            }
            currentNetworkType = networkType
        }
    }

    func restartClient() {
        AppLogger.shared.log("restartClient: starting restart sequence")
        adapter.isRestarting = true
        adapter.stop { [weak self] in
            AppLogger.shared.log("restartClient: stop completed, starting client")
            self?.adapter.start { error in
                if let error = error {
                    self?.adapter.isRestarting = false
                    AppLogger.shared.log("restartClient: start failed - \(error.localizedDescription)")
                    Analytics.logEvent("packet_tunnel_provider", parameters: [
                        "level": "ERROR",
                        "method": "restartClient",
                        "error" : error.localizedDescription
                    ])
                } else {
                    // Note: isRestarting is already cleared by onConnected() callback
                    self?.adapter.isRestarting = false
                    AppLogger.shared.log("restartClient: start completed successfully")
                }
            }
        }
    }

    func sendLoginRequiredNotification() {
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
                AppLogger.shared.log("Failed to send login notification: \(error.localizedDescription)")
            } else {
                AppLogger.shared.log("Login required notification sent")
            }
        }
    }

    func login(completionHandler: (Data?) -> Void) {
        let urlString = adapter.login()
        let data = urlString.data(using: .utf8)
        completionHandler(data)
    }

    func getStatus(completionHandler: (Data?) -> Void) {
        guard let statusDetailsMessage = adapter.client.getStatusDetails() else {
            print("Did not receive status details.")
            completionHandler(nil)
            return
        }

        var peerInfoArray: [PeerInfo] = []
        for i in 0..<statusDetailsMessage.size() {
            guard let peer = statusDetailsMessage.get(i) else { continue }
            let routes = peer.getRouteDetails()

            var routesArray: [String] = []
            for j in 0..<(routes?.size() ?? 0) {
                if let route = routes?.get(j) {
                    routesArray.append(route.route)
                }
            }

            let peerInfo = PeerInfo(
                ip: peer.ip,
                fqdn: peer.fqdn,
                localIceCandidateEndpoint: peer.localIceCandidateEndpoint,
                remoteIceCandidateEndpoint: peer.remoteIceCandidateEndpoint,
                localIceCandidateType: peer.localIceCandidateType,
                remoteIceCandidateType: peer.remoteIceCandidateType,
                pubKey: peer.pubKey,
                latency: peer.latency,
                bytesRx: peer.bytesRx,
                bytesTx: peer.bytesTx,
                connStatus: peer.connStatus,
                connStatusUpdate: peer.connStatusUpdate,
                direct: peer.direct,
                lastWireguardHandshake: peer.lastWireguardHandshake,
                relayed: peer.relayed,
                rosenpassEnabled: peer.rosenpassEnabled,
                routes: routesArray
            )
            peerInfoArray.append(peerInfo)
        }

        let statusDetails = StatusDetails(
            ip: statusDetailsMessage.getIP(),
            fqdn: statusDetailsMessage.getFQDN(),
            managementStatus: adapter.clientState,
            peerInfo: peerInfoArray
        )

        do {
            let data = try PropertyListEncoder().encode(statusDetails)
            completionHandler(data)
        } catch {
            print("Failed to encode status details: \(error.localizedDescription)")
            do {
                let defaultStatus = StatusDetails(ip: "", fqdn: "", managementStatus: adapter.clientState, peerInfo: [])
                let data = try PropertyListEncoder().encode(defaultStatus)
                completionHandler(data)
            } catch {
                print("Failed to encode default status: \(error.localizedDescription)")
                completionHandler(nil)
            }
        }
    }

    func getSelectRoutes(completionHandler: (Data?) -> Void) {
        do {
            let routeSelectionDetailsMessage = try adapter.client.getRoutesSelectionDetails()

            let routeSelectionInfo: [RoutesSelectionInfo] = (0..<routeSelectionDetailsMessage.size()).compactMap { index in
                guard let route = routeSelectionDetailsMessage.get(index) else { return nil }

                let domains = (0..<(route.domains?.size() ?? 0)).compactMap { domainIndex -> DomainDetails? in
                    guard let domain = route.domains?.get(domainIndex) else { return nil }
                    return DomainDetails(domain: domain.domain, resolvedips: domain.resolvedIPs)
                }

                return RoutesSelectionInfo(
                    name: route.id_,
                    network: route.network,
                    domains: domains,
                    selected: route.selected
                )
            }

            let routeSelectionDetails = RoutesSelectionDetails(
                all: routeSelectionDetailsMessage.all,
                append: routeSelectionDetailsMessage.append,
                routeSelectionInfo: routeSelectionInfo
            )

            let data = try PropertyListEncoder().encode(routeSelectionDetails)
            completionHandler(data)
        } catch {
            print("Error retrieving or encoding route selection details: \(error.localizedDescription)")
            let defaultStatus = RoutesSelectionDetails(all: false, append: false, routeSelectionInfo: [])
            do {
                let data = try PropertyListEncoder().encode(defaultStatus)
                completionHandler(data)
            } catch {
                print("Failed to encode default route selection details: \(error.localizedDescription)")
                completionHandler(nil)
            }
        }
    }

    func selectRoute(id: String) {
        do {
            try adapter.client.selectRoute(id)
        } catch {
            print("Failed to select route: \(error.localizedDescription)")
        }
    }

    func deselectRoute(id: String) {
        do {
            try adapter.client.deselectRoute(id)
        } catch {
            print("Failed to deselect route: \(error.localizedDescription)")
        }
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    override func wake() {
    }

    func setTunnelSettings(tunnelNetworkSettings: NEPacketTunnelNetworkSettings) {
        setTunnelNetworkSettings(tunnelNetworkSettings) { error in
            if let error = error {
                print("Error assigning routes: \(error.localizedDescription)")
                return
            }
            print("Routes set successfully.")
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
