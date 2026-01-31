//
//  PacketTunnelProvider.swift
//  NetbirdNetworkExtension
//
//  Created by Pascal Fischer on 06.08.23.
//

import NetworkExtension
import Network
import os
import UserNotifications


class PacketTunnelProvider: NEPacketTunnelProvider {

    private lazy var tunnelManager: PacketTunnelProviderSettingsManager = {
        return PacketTunnelProviderSettingsManager(with: self)
    }()

    private lazy var adapter: NetBirdAdapter? = {
        return NetBirdAdapter(with: self.tunnelManager)
    }()

    var pathMonitor: NWPathMonitor?
    let monitorQueue = DispatchQueue(label: "NetworkMonitor")

    /// Network state variables - accessed only on monitorQueue for thread safety
    private var currentNetworkType: NWInterface.InterfaceType?
    private var wasStoppedDueToNoNetwork = false

    /// Stuck state detection - for auto-recovery when SDK fails to reconnect
    /// Tracks both "Connecting" and "Disconnected" states when tunnel is up
    private var stuckStateStartTime: Date?
    private var stuckRestartAttempts: Int = 0
    private var lastStuckRestartTime: Date?
    private let stuckStateThreshold: TimeInterval = 60  // seconds before considering "stuck"
    private let maxStuckRestartAttempts: Int = 3
    private let minTimeBetweenStuckRestarts: TimeInterval = 60  // minimum backoff between attempts

    /// Thread-safe restart progress flag
    private let restartLock = NSLock()
    private var _isRestartInProgress = false
    private var isRestartInProgress: Bool {
        get { restartLock.lock(); defer { restartLock.unlock() }; return _isRestartInProgress }
        set { restartLock.lock(); defer { restartLock.unlock() }; _isRestartInProgress = newValue }
    }

    /// Flag to indicate tunnel is being intentionally stopped (user disconnect)
    /// Prevents stuck recovery from triggering during shutdown
    private var isTunnelStopping = false
    
    private var networkChangeWorkItem: DispatchWorkItem?

    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        if let options = options, let logLevel = options["logLevel"] as? String {
            initializeLogging(loglevel: logLevel)
        }

        isTunnelStopping = false
        monitorQueue.async { [weak self] in
            self?.currentNetworkType = nil
            self?.wasStoppedDueToNoNetwork = false
            self?.isRestartInProgress = false
            self?.stuckStateStartTime = nil
            self?.stuckRestartAttempts = 0
            self?.lastStuckRestartTime = nil
            self?.startMonitoringNetworkChanges()
        }

        guard let adapter = adapter else {
            let error = NSError(
                domain: "io.netbird.NetbirdNetworkExtension",
                code: 1003,
                userInfo: [NSLocalizedDescriptionKey: "Failed to initialize NetBird adapter."]
            )
            completionHandler(error)
            return
        }

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
        isTunnelStopping = true
        monitorQueue.async { [weak self] in
            self?.networkChangeWorkItem?.cancel()
            self?.networkChangeWorkItem = nil
            self?.currentNetworkType = nil
            self?.wasStoppedDueToNoNetwork = false
            self?.isRestartInProgress = false
        }
        adapter?.stop()
        guard let pathMonitor = self.pathMonitor else {
            AppLogger.shared.log("pathMonitor is nil; nothing to cancel.")
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
            completionHandler("true".data(using: .utf8))
        case let s where s.hasPrefix("Deselect-"):
            let id = String(s.dropFirst("Deselect-".count))
            deselectRoute(id: id)
            completionHandler("true".data(using: .utf8))
        default:
            AppLogger.shared.log("Unknown message: \(string)")
            completionHandler(nil)
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
        AppLogger.shared.log("""
                  Path update:
                  - status: \(path.status)
                  - isExpensive: \(path.isExpensive)
                  - usesWifi: \(path.usesInterfaceType(.wifi))
                  - usesCellular: \(path.usesInterfaceType(.cellular))
                  - interfaces: \(path.availableInterfaces.map { $0.type })
                  """)

        if path.status != .satisfied {
            AppLogger.shared.log("No network connection detected")
            
            // Cancel any pending restart
            networkChangeWorkItem?.cancel()
            networkChangeWorkItem = nil

            // Signal UI to show disconnecting animation via shared flag
            // We don't call adapter.stop() to avoid race conditions with Go SDK callbacks
            // The Go SDK will handle network loss internally and reconnect when available
            if !wasStoppedDueToNoNetwork {
                let stateDesc = adapter?.clientState.description ?? "unknown"
                AppLogger.shared.log("Network unavailable - signaling UI for disconnecting animation, clientState=\(stateDesc)")
                wasStoppedDueToNoNetwork = true
                setNetworkUnavailableFlag(true)
            }
            return
        }

        // Network is available again
        let shouldRestartDueToRecovery = wasStoppedDueToNoNetwork
        if wasStoppedDueToNoNetwork {
            AppLogger.shared.log("Network restored after unavailability - signaling UI")
            wasStoppedDueToNoNetwork = false
            setNetworkUnavailableFlag(false)
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

        let networkTypeChanged = currentNetworkType != nil && currentNetworkType != networkType

        if networkTypeChanged {
            AppLogger.shared.log("Network type changed: \(String(describing: currentNetworkType)) -> \(networkType)")
        }

        // Restart if network type changed OR recovering from network unavailability
        // (even if returning to the same interface type, the connection may be stale)
        if networkTypeChanged || shouldRestartDueToRecovery {
            // Cancel any pending restart from previous rapid change
            networkChangeWorkItem?.cancel()
            networkChangeWorkItem = nil

            // Debounce: schedule restart after 1 second
            let workItem = DispatchWorkItem { [weak self] in
                self?.restartClient()
            }

            networkChangeWorkItem = workItem
            monitorQueue.asyncAfter(deadline: .now() + 1.0, execute: workItem)
        }

        currentNetworkType = networkType
    }

    func restartClient() {
        guard let adapter = adapter else {
            AppLogger.shared.log("restartClient: adapter is nil")
            return
        }

        if isRestartInProgress {
            AppLogger.shared.log("restartClient: skipping - restart already in progress")
            return
        }
        AppLogger.shared.log("restartClient: starting restart sequence")
        isRestartInProgress = true
        adapter.isRestarting = true

        // Timeout after 30 seconds to reset flags if restart hangs
        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            guard let self = self, self.isRestartInProgress else { return }
            AppLogger.shared.log("restartClient: timeout - resetting flags")
            self.adapter?.isRestarting = false
            self.isRestartInProgress = false
        }
        monitorQueue.asyncAfter(deadline: .now() + 30, execute: timeoutWorkItem)

        adapter.stop { [weak self] in
            AppLogger.shared.log("restartClient: stop completed, starting client")
            self?.adapter?.start { error in
                // Cancel timeout whether start succeeds or not
                timeoutWorkItem.cancel()

                self?.monitorQueue.async {
                    self?.adapter?.isRestarting = false
                    self?.isRestartInProgress = false
                }

                if let error = error {
                    AppLogger.shared.log("restartClient: start failed - \(error.localizedDescription)")
                } else {
                    AppLogger.shared.log("restartClient: start completed successfully")
                }
            }
        }
    }

    /// Detects when SDK is stuck in "Connecting" or "Disconnected" state for too long and attempts recovery.
    /// This handles cases where the SDK loses connectivity to management/signal servers and can't recover.
    private func checkAndRecoverFromStuckState(clientState: ClientState, isRestarting: Bool) {
        // If connected, reset all stuck tracking state
        if clientState == .connected {
            if stuckStateStartTime != nil {
                AppLogger.shared.log("stuckRecovery: SDK recovered to Connected, resetting stuck tracking")
            }
            stuckStateStartTime = nil
            stuckRestartAttempts = 0
            return
        }

        // Track both "connecting" and "disconnected" states (when tunnel is presumably still up)
        // Skip "disconnecting" as that's a transient state
        guard clientState == .connecting || clientState == .disconnected else {
            stuckStateStartTime = nil
            return
        }

        // Don't attempt recovery if a restart is already in progress
        if isRestarting || isRestartInProgress {
            stuckStateStartTime = nil
            return
        }

        // Don't attempt recovery if tunnel is being intentionally stopped
        if isTunnelStopping {
            stuckStateStartTime = nil
            return
        }

        // Start tracking if this is the first time we see a stuck-eligible state
        if stuckStateStartTime == nil {
            stuckStateStartTime = Date()
            AppLogger.shared.log("stuckRecovery: Started tracking \(clientState) state")
            return
        }

        // Check how long we've been in this state
        let stuckDuration = Date().timeIntervalSince(stuckStateStartTime!)

        // Not stuck yet
        guard stuckDuration >= stuckStateThreshold else {
            return
        }

        // Check if we've exceeded max restart attempts - force disconnect
        if stuckRestartAttempts >= maxStuckRestartAttempts {
            AppLogger.shared.log("stuckRecovery: Max restart attempts (\(maxStuckRestartAttempts)) reached, forcing tunnel disconnect")
            stuckStateStartTime = nil
            let error = NSError(
                domain: "io.netbird.NetbirdNetworkExtension",
                code: 1004,
                userInfo: [NSLocalizedDescriptionKey: "Connection failed after \(maxStuckRestartAttempts) recovery attempts. Please reconnect manually."]
            )
            cancelTunnelWithError(error)
            return
        }

        // Check backoff - don't restart too frequently
        if let lastRestart = lastStuckRestartTime {
            let timeSinceLastRestart = Date().timeIntervalSince(lastRestart)
            if timeSinceLastRestart < minTimeBetweenStuckRestarts {
                return
            }
        }

        // Check if network is available before attempting restart
        guard let path = pathMonitor?.currentPath, path.status == .satisfied else {
            AppLogger.shared.log("stuckRecovery: Network not available, skipping restart")
            return
        }

        // Trigger restart
        stuckRestartAttempts += 1
        lastStuckRestartTime = Date()
        stuckStateStartTime = nil  // Reset so we can track the next attempt

        AppLogger.shared.log("stuckRecovery: SDK stuck in \(clientState) for \(Int(stuckDuration))s, attempting restart (attempt \(stuckRestartAttempts)/\(maxStuckRestartAttempts))")

        monitorQueue.async { [weak self] in
            self?.restartClient()
        }
    }

    /// Signals login required by persisting a flag to the shared app-group container.
    /// The main app reads this flag when it becomes active and handles notification scheduling.
    /// Direct notification from extension is best-effort only since NEPacketTunnelProvider
    /// notification scheduling is unreliable.
    func signalLoginRequired() {
        let userDefaults = UserDefaults(suiteName: GlobalConstants.userPreferencesSuiteName)
        userDefaults?.set(true, forKey: GlobalConstants.keyLoginRequired)
        userDefaults?.synchronize()
        AppLogger.shared.log("Login required flag set in shared container")

        // Best-effort notification attempt from extension (may not work reliably)
        sendLoginNotificationBestEffort()
    }

    private func sendLoginNotificationBestEffort() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else {
                AppLogger.shared.log("Notifications not authorized, skipping extension notification attempt")
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
                    AppLogger.shared.log("Extension notification attempt failed (expected): \(error.localizedDescription)")
                } else {
                    AppLogger.shared.log("Extension notification attempt succeeded")
                }
            }
        }
    }

    func setNetworkUnavailableFlag(_ unavailable: Bool) {
        let userDefaults = UserDefaults(suiteName: GlobalConstants.userPreferencesSuiteName)
        userDefaults?.set(unavailable, forKey: GlobalConstants.keyNetworkUnavailable)
        userDefaults?.synchronize()
        AppLogger.shared.log("Network unavailable flag set to \(unavailable)")
    }

    func login(completionHandler: (Data?) -> Void) {
        guard let adapter = adapter else {
            completionHandler(nil)
            return
        }
        let urlString = adapter.login()
        let data = urlString.data(using: .utf8)
        completionHandler(data)
    }

    func getStatus(completionHandler: (Data?) -> Void) {
        guard let adapter = adapter else {
            completionHandler(nil)
            return
        }
        guard let statusDetailsMessage = adapter.client.getStatusDetails() else {
            AppLogger.shared.log("Did not receive status details.")
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

        let clientState = adapter.clientState
        let adapterRestarting = adapter.isRestarting
        let providerRestarting = isRestartInProgress
        let isRestarting = adapterRestarting || providerRestarting
        AppLogger.shared.log("getStatus: clientState=\(clientState), adapterRestarting=\(adapterRestarting), providerRestarting=\(providerRestarting), isRestarting=\(isRestarting)")

        // Detect and recover from stuck state
        checkAndRecoverFromStuckState(clientState: clientState, isRestarting: isRestarting)

        let statusDetails = StatusDetails(
            ip: statusDetailsMessage.getIP(),
            fqdn: statusDetailsMessage.getFQDN(),
            managementStatus: clientState,
            peerInfo: peerInfoArray,
            isRestarting: isRestarting
        )

        do {
            let data = try PropertyListEncoder().encode(statusDetails)
            completionHandler(data)
        } catch {
            AppLogger.shared.log("Failed to encode status details: \(error.localizedDescription)")
            do {
                let defaultStatus = StatusDetails(ip: "", fqdn: "", managementStatus: clientState, peerInfo: [], isRestarting: isRestarting)
                let data = try PropertyListEncoder().encode(defaultStatus)
                completionHandler(data)
            } catch {
                AppLogger.shared.log("Failed to encode default status: \(error.localizedDescription)")
                completionHandler(nil)
            }
        }
    }

    func getSelectRoutes(completionHandler: (Data?) -> Void) {
        guard let adapter = adapter else {
            completionHandler(nil)
            return
        }
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
            AppLogger.shared.log("Error retrieving or encoding route selection details: \(error.localizedDescription)")
            let defaultStatus = RoutesSelectionDetails(all: false, append: false, routeSelectionInfo: [])
            do {
                let data = try PropertyListEncoder().encode(defaultStatus)
                completionHandler(data)
            } catch {
                AppLogger.shared.log("Failed to encode default route selection details: \(error.localizedDescription)")
                completionHandler(nil)
            }
        }
    }

    func selectRoute(id: String) {
        guard let adapter = adapter else { return }
        do {
            try adapter.client.selectRoute(id)
        } catch {
            AppLogger.shared.log("Failed to select route: \(error.localizedDescription)")
        }
    }

    func deselectRoute(id: String) {
        guard let adapter = adapter else { return }
        do {
            try adapter.client.deselectRoute(id)
        } catch {
            AppLogger.shared.log("Failed to deselect route: \(error.localizedDescription)")
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
                AppLogger.shared.log("Error assigning routes: \(error.localizedDescription)")
                return
            }
            AppLogger.shared.log("Routes set successfully.")
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
            AppLogger.shared.log("Failed to get the log file URL.")
            return
        }
    
    if fileManager.fileExists(atPath: logURLValid.path) {
        if let fileHandle = try? FileHandle(forWritingTo: logURLValid) {
            do {
                try "".write(to: logURLValid, atomically: true, encoding: .utf8)
            } catch {
                AppLogger.shared.log("Error handling the log file: \(error)")
            }
            if let data = logMessage.data(using: .utf8) {
                fileHandle.write(data)
            }
            fileHandle.closeFile()
        } else {
            AppLogger.shared.log("Failed to open the log file for writing.")
        }
    } else {
        do {
            try logMessage.write(to: logURLValid, atomically: true, encoding: .utf8)
        } catch {
            AppLogger.shared.log("Failed to write to the log file: \(error.localizedDescription)")
        }
    }
    
    if let logPath = logURL?.path {
        success = NetBirdSDKInitializeLog(loglevel, logPath, &error)
    }
    if !success, let actualError = error {
       AppLogger.shared.log("Failed to initialize log: \(actualError.localizedDescription)")
   }
}
