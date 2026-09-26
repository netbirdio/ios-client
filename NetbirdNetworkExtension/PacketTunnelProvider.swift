//
//  PacketTunnelProvider.swift
//  NetbirdNetworkExtension
//
//  Created by Pascal Fischer on 06.08.23.
//

import NetworkExtension
import Network
import NetBirdSDK
import os
import UserNotifications
import WidgetKit
#if os(iOS)
import CoreTelephony
#endif

/// One-time (per process) redirect of stderr (fd 2) into "netbird.err" in the app
/// group container. The Go runtime writes panic messages and fatal-error goroutine
/// dumps to fd 2, which an app extension otherwise discards — after a SIGABRT crash
/// this file is the only place the panic reason can be recovered from.
/// The file lives next to logfile.log, so the debug bundle generator picks it up
/// automatically as "netbird.err" (see BundleGenerator.addLogfile in netbird-core).
private let stderrRedirectOnce: Void = {
    let fileManager = FileManager.default
    guard let groupURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: GlobalConstants.userPreferencesSuiteName) else {
        AppLogger.shared.log("stderr redirect: app group container unavailable")
        return
    }
    let errLogURL = groupURL.appendingPathComponent("netbird.err")

    if let attrs = try? fileManager.attributesOfItem(atPath: errLogURL.path),
       let size = attrs[.size] as? UInt64, size > 0 {
        // Surface a previous session's crash output before appending to it.
        AppLogger.shared.log("stderr redirect: netbird.err has \(size) bytes from a previous session (possible crash dump)")
        // Cap growth across sessions: reset once it grows beyond 5 MB.
        if size > 5 * 1024 * 1024 {
            AppLogger.shared.log("stderr redirect: netbird.err exceeds 5 MB cap, resetting")
            try? fileManager.removeItem(at: errLogURL)
        }
    }

    let fd = open(errLogURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    guard fd >= 0 else {
        AppLogger.shared.log("stderr redirect: failed to open \(errLogURL.path), errno=\(errno)")
        return
    }
    dup2(fd, STDERR_FILENO)
    if fd != STDERR_FILENO {
        close(fd)
    }

    let marker = "\n=== stderr redirect active pid=\(getpid()) at \(ISO8601DateFormatter().string(from: Date())) ===\n"
    marker.withCString { _ = write(STDERR_FILENO, $0, strlen($0)) }
    AppLogger.shared.log("stderr redirect: fd 2 -> netbird.err in app group container")
}()


class PacketTunnelProvider: NEPacketTunnelProvider {

    override init() {
        // Must run before any Go SDK call so a Go panic during startup is captured too.
        _ = stderrRedirectOnce
        super.init()
    }

    private lazy var tunnelManager: PacketTunnelProviderSettingsManager = {
        return PacketTunnelProviderSettingsManager(with: self)
    }()

    private var adapter: NetBirdAdapter?

    var pathMonitor: NWPathMonitor?
    let monitorQueue = DispatchQueue(label: "NetworkMonitor")

    /// Network state variables - accessed only on monitorQueue for thread safety
    private var reconnection = NetworkReconnectionState()
    #if os(iOS)
    private var telephonyInfo: CTTelephonyNetworkInfo?
    #endif

    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        if let options = options, let logLevel = options["logLevel"] as? String {
            initializeLogging(loglevel: logLevel)
        }

        // Extract profile paths passed from the main app via startVPNTunnel(options:).
        // If paths differ from what the current adapter was initialized with, recreate
        // the adapter so it uses the correct profile's config and state files.
        #if os(iOS)
        let configPath = (options?["configPath"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let statePath  = (options?["statePath"]  as? String).flatMap { $0.isEmpty ? nil : $0 }
        if adapter == nil || (configPath != nil && configPath != adapter?.initializedConfigPath) {
            AppLogger.shared.log("PacketTunnelProvider: (re)creating adapter for configPath=\(configPath ?? "default")")
            // Detach the outgoing adapter's Go callbacks before discarding it so a late
            // callback from the old client can't reach into the tunnel manager once the
            // new adapter has replaced it (EXC_BAD_ACCESS / 0x28 during profile switch).
            adapter?.invalidateListeners()
            adapter = NetBirdAdapter(with: tunnelManager, configPath: configPath, statePath: statePath)
        }
        #else
        if adapter == nil {
            adapter = NetBirdAdapter(with: tunnelManager)
        }
        #endif

        guard let adapter = adapter else {
            let error = NSError(
                domain: "io.netbird.NetbirdNetworkExtension",
                code: 1003,
                userInfo: [NSLocalizedDescriptionKey: "Failed to initialize NetBird adapter."]
            )
            completionHandler(error)
            return
        }

        // The engine owns authentication and retries transport failures. A preflight
        // Login RPC would misclassify an offline On Demand/widget start as expired
        // credentials. Actual auth denial still reaches onLoginRequired below.

        // Wire up the login-required callback so the connection listener can tear the
        // tunnel down if the auth session expires mid-session (token expires while the
        // VPN is running). On Android the kernel removes the VPN routes automatically
        // when the Go engine closes the TUN fd; on iOS the utun interface is owned by
        // the provider and outlives the Go engine, so without an explicit teardown it
        // lingers with the default route and black-holes all traffic until the user
        // opens the app. cancelTunnelWithError restores the default route immediately.
        let sessionID = monitorQueue.sync {
            stopMonitoringNetworkChanges()
            reconnection = NetworkReconnectionState()
            adapter.isNetworkUnavailable = false
            startMonitoringNetworkChanges()
            return reconnection.sessionID
        }
        adapter.onLoginRequired = { [weak self] in
            self?.monitorQueue.async {
                guard let self, self.reconnection.isActive,
                      self.reconnection.sessionID == sessionID else { return }
                AppLogger.shared.log("onLoginRequired: session expired mid-tunnel — tearing down")
                let initialCompletion = self.reconnection.completeStart()
                self.stopMonitoringNetworkChanges()
                self.signalLoginRequired()
                self.updateWidgetStatus("disconnected")
                let error = NSError(
                    domain: "io.netbird.NetbirdNetworkExtension",
                    code: 1001,
                    userInfo: [NSLocalizedDescriptionKey: "Login required."]
                )
                if initialCompletion {
                    completionHandler(error)
                } else {
                    self.cancelTunnelWithError(error)
                }
            }
        }
        adapter.start(onConnectionChanged: { [weak self] state in
            self?.monitorQueue.async {
                guard let self, self.reconnection.isActive,
                      self.reconnection.sessionID == sessionID else { return }
                self.reconnection.connectionChanged(state)
                self.reasserting = self.reconnection.isReasserting
            }
        }) { [weak self] error in
            self?.monitorQueue.async {
                guard let self, self.reconnection.isActive,
                      self.reconnection.sessionID == sessionID else { return }
                let initialCompletion = self.reconnection.completeStart()
                if initialCompletion { completionHandler(error) }
                if let error {
                    self.stopMonitoringNetworkChanges()
                    self.updateWidgetStatus("disconnected")
                    if !initialCompletion { self.cancelTunnelWithError(error) }
                } else {
                    self.updateWidgetStatus("connected")
                }
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        // Ignore queued path/SIM callbacks once the user stops the tunnel.
        monitorQueue.sync {
            stopMonitoringNetworkChanges()
            adapter?.isRestarting = false
            adapter?.isNetworkUnavailable = false
        }
        setNetworkUnavailableFlag(false)
        // The extension has a short shutdown deadline; do not wait for Go teardown.
        adapter?.client.stopWithoutWait()
        updateWidgetStatus("disconnected")
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
        case let s where s.hasPrefix("Login:"):
            // Format: "Login:<configPath>|<statePath>[|<managementURL>]"
            let payload = String(s.dropFirst("Login:".count))
            let parts = payload.components(separatedBy: "|")
            if parts.count >= 2 {
                let configPath    = parts[0]
                let statePath     = parts[1]
                let managementURL = parts.count >= 3 ? parts[2] : nil

                // If the config file is missing (e.g. after logout) but we received
                // the profile's management URL, write a minimal config in the Go SDK's
                // url.URL nested-object format so the SDK uses the correct server instead
                // of falling back to the default api.netbird.io.
                var configRestored = false
                if let url = managementURL, !url.isEmpty,
                   !FileManager.default.fileExists(atPath: configPath),
                   let parsedURL = URL(string: url) {
                    let scheme = parsedURL.scheme ?? "https"
                    var goHost = parsedURL.host ?? ""
                    if let port = parsedURL.port { goHost += ":\(port)" }
                    let path = parsedURL.path
                    func jsonEscape(_ s: String) -> String {
                        s.replacingOccurrences(of: "\\", with: "\\\\")
                         .replacingOccurrences(of: "\"", with: "\\\"")
                    }
                    let minimalConfig = "{\"ManagementURL\":{\"Scheme\":\"\(jsonEscape(scheme))\",\"Host\":\"\(jsonEscape(goHost))\",\"Path\":\"\(jsonEscape(path))\"}}"
                    AppLogger.shared.log("handleAppMessage: config missing, writing minimal config for URL \(url)")
                    if (try? minimalConfig.write(toFile: configPath, atomically: true, encoding: .utf8)) != nil {
                        configRestored = true
                    }
                }

                if configPath != adapter?.initializedConfigPath || configRestored {
                    AppLogger.shared.log("handleAppMessage: (re)creating adapter for \(configPath)")
                    // Detach the outgoing adapter's Go callbacks before discarding it (see startTunnel).
                    adapter?.invalidateListeners()
                    adapter = NetBirdAdapter(with: tunnelManager, configPath: configPath, statePath: statePath)
                }
            }
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
        case let s where s.hasPrefix("DebugBundle:"):
            let anonymize = s.dropFirst("DebugBundle:".count) == "true"
            debugBundle(anonymize: anonymize, completionHandler: completionHandler)
        default:
            AppLogger.shared.log("Unknown message: \(string)")
            completionHandler(nil)
        }
    }

    func startMonitoringNetworkChanges() {
        #if os(iOS)
        let info = CTTelephonyNetworkInfo()
        info.delegate = self
        telephonyInfo = info
        #endif
        let monitor = NWPathMonitor(prohibitedInterfaceTypes: [.other, .loopback])
        monitor.pathUpdateHandler = { [weak self, weak monitor] path in
            guard let self, let monitor, self.pathMonitor === monitor else { return }
            self.handleNetworkChange(path: path)
        }
        pathMonitor = monitor
        monitor.start(queue: monitorQueue)
    }

    private func stopMonitoringNetworkChanges() {
        reconnection.stop()
        reasserting = false
        pathMonitor?.cancel()
        pathMonitor = nil
        #if os(iOS)
        telephonyInfo?.delegate = nil
        telephonyInfo = nil
        #endif
    }

    func handleNetworkChange(path: Network.NWPath, forceRefresh: Bool = false) {
        guard reconnection.isActive else { return }
        let available = NetworkReconnectionState.allowsConnectionAttempts(path.status)
        #if os(iOS)
        let service = telephonyInfo?.dataServiceIdentifier
        #else
        let service: String? = nil
        #endif
        let network = available ? UnderlyingNetwork(path: path, dataServiceIdentifier: service) : nil
        guard let change = reconnection.update(network, forceRefresh: forceRefresh) else { return }
        AppLogger.shared.log("Network path: available=\(available), interfaces=\(network?.interfaces ?? []), changed=\(change.networkChanged)")
        adapter?.isNetworkUnavailable = !available
        if !available {
            // Reflect path loss immediately; the SDK also reports reconnecting.
            reconnection.connectionChanged(.connecting)
            reasserting = reconnection.isReasserting
        }
        setNetworkUnavailableFlag(!available)
        // The core parks retries while offline and wakes them with fresh backoff.
        adapter?.client.setNetworkAvailable(available)
        if change.networkChanged {
            // The core coalesces changes and sweeps stale connections/dials. Keep
            // delivering events while reconnecting so a second SIM switch is not lost.
            adapter?.client.notifyNetworkChange()
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
        // Skip authorization check — in a Network Extension context,
        // UNUserNotificationCenter reports the extension bundle's status
        // (always .notDetermined), not the containing app's granted permission.
        // Attempt delivery unconditionally and let the system reject if needed.
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("notification_login_required_title", value: "VPN Disconnected", comment: "")
        content.body = NSLocalizedString("notification_login_required_body", value: "Re-authentication required. Tap to log in and restore your VPN connection.", comment: "")
        content.sound = .default

        // Delayed so the main app process (if backgrounded) can cancel this pending request
        // and deliver its own — prevents the duplicate that occurs when both paths fire.
        // If the app is force-quit, the delay expires and this notification fires instead.
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false)
        let request = UNNotificationRequest(
            identifier: GlobalConstants.notificationLoginRequired,
            content: content,
            trigger: trigger
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                AppLogger.shared.log("Extension notification attempt failed: \(error.localizedDescription)")
            } else {
                AppLogger.shared.log("Extension notification scheduled with 3s delay")
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
                ipv6: peer.iPv6,
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
        let statusDetails = StatusDetails(
            ip: statusDetailsMessage.getIP(),
            ipv6: statusDetailsMessage.getIPv6(),
            fqdn: statusDetailsMessage.getFQDN(),
            managementStatus: clientState,
            peerInfo: peerInfoArray
        )

        do {
            let data = try PropertyListEncoder().encode(statusDetails)
            completionHandler(data)
        } catch {
            AppLogger.shared.log("Failed to encode status details: \(error.localizedDescription)")
            do {
                let defaultStatus = StatusDetails(ip: "", fqdn: "", managementStatus: clientState, peerInfo: [])
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

            let routeSelectionInfo: [RoutesSelectionInfo] = (0..<routeSelectionDetailsMessage.size()).compactMap { index -> RoutesSelectionInfo? in
                guard let route = routeSelectionDetailsMessage.get(index) else { return nil }

                let domainCount = route.domains.map { $0.size() } ?? 0
                let domains = (0..<domainCount).compactMap { domainIndex -> DomainDetails? in
                    guard let domain = route.domains?.get(domainIndex) else { return nil }
                    let resolvedIPsRef = domain.getResolvedIPs()
                    let resolvedIPs: [String] = (0..<(resolvedIPsRef?.size() ?? 0)).map { ipIndex in
                        resolvedIPsRef?.get(ipIndex) ?? ""
                    }.filter { !$0.isEmpty }
                    return DomainDetails(domain: domain.domain, resolvedIPs: resolvedIPs)
                }

                return RoutesSelectionInfo(
                    name: route.id_,
                    network: route.network,
                    domains: domains,
                    selected: route.selected,
                    status: route.status
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

    func debugBundle(anonymize: Bool, completionHandler: @escaping (Data?) -> Void) {
        guard let adapter = adapter else {
            completionHandler("error:adapter not available".data(using: .utf8))
            return
        }
        DispatchQueue.global(qos: .utility).async {
            var error: NSError?
            // The strict level stays unused until the troubleshoot screen
            // grows an option for it.
            let key = adapter.client.debugBundle(anonymize, anonymizeLevel: NetBirdSDKAnonymizeLevelDefault, error: &error)
            if let error = error {
                completionHandler("error:\(error.localizedDescription)".data(using: .utf8))
            } else {
                completionHandler(key.data(using: .utf8))
            }
        }
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    override func wake() {
        monitorQueue.async { [weak self] in
            guard let self, self.reconnection.isActive, let monitor = self.pathMonitor else { return }
            // Addresses can stay unchanged while NAT mappings and sockets expire
            // during sleep. Refresh through the same coalesced sweep as a handover.
            self.handleNetworkChange(path: monitor.currentPath, forceRefresh: true)
        }
    }

    /// Writes the resolved VPN status to shared UserDefaults and triggers a widget reload.
    /// Called from start/stop completion so the widget reflects the real tunnel state
    /// without waiting for the widget's own polling cycle.
    private func updateWidgetStatus(_ status: String) {
        let defaults = UserDefaults(suiteName: GlobalConstants.userPreferencesSuiteName)
        defaults?.set(status, forKey: GlobalConstants.keyWidgetVPNStatus)
        AppLogger.shared.log("updateWidgetStatus: \(status)")
        // For "connected", delay the reload by 1 s so the NE connection status has time
        // to propagate from the tunnel process to the widget extension process before
        // VPNStatusProvider queries NETunnelProviderManager.loadAllFromPreferences().
        // Without this delay the widget briefly shows "Disconnected / Connect" right
        // after a successful connect, then stays wrong until the next poll.
        let delay: TimeInterval = (status == "connected") ? 1.0 : 0.0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            WidgetCenter.shared.reloadAllTimelines()
        }
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

#if os(iOS)
extension PacketTunnelProvider: CTTelephonyNetworkInfoDelegate {
    func dataServiceIdentifierDidChange(_ identifier: String) {
        // CoreTelephony calls on a global queue. Read the current service on our
        // queue rather than trusting a potentially superseded callback argument.
        monitorQueue.async { [weak self] in
            guard let self, let monitor = self.pathMonitor else { return }
            self.handleNetworkChange(path: monitor.currentPath)
        }
    }
}
#endif
