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

class PacketTunnelProvider: NEPacketTunnelProvider {

    override init() {
        // Must run before any Go SDK call so a Go panic during startup is captured too.
        GoCrashCapture.redirect()
        super.init()
    }

    private lazy var tunnelManager: PacketTunnelProviderSettingsManager = {
        return PacketTunnelProviderSettingsManager(with: self)
    }()

    private var adapter: NetBirdAdapter?

    var pathMonitor: NWPathMonitor?
    let monitorQueue = DispatchQueue(label: "NetworkMonitor")

    /// Network state variables - accessed only on monitorQueue for thread safety
    private var currentNetworkType: NWInterface.InterfaceType?
    private var wasStoppedDueToNoNetwork = false
    private var isRestartInProgress = false
    /// Set from the moment startTunnel arms the connection until the adapter reports its
    /// outcome. Network-change restarts are held off while it is set, so a connection that
    /// is still being established is never torn down mid-flight.
    private var isInitialStartInFlight = false
    
    private var networkChangeWorkItem: DispatchWorkItem?
    private var networkLossWorkItem: DispatchWorkItem?
    private var initialStartTimeoutWorkItem: DispatchWorkItem?

    /// A path that stays unsatisfied for less than this is a blip, not an outage. The engine
    /// pushes the interface address, the routes and the DNS config separately during a single
    /// connect, and each one re-applies the tunnel settings; treating the resulting flap as an
    /// outage plus a recovery is what made the tunnel connect and disconnect repeatedly
    /// before settling.
    private static let networkLossDebounce: TimeInterval = 2.0
    /// Upper bound on the initial-start guard. A start that never reports its outcome must not
    /// block network-change restarts for the rest of the tunnel's life.
    private static let initialStartGuardTimeout: TimeInterval = 30.0

    /// NE requires the startTunnel completion handler to be called exactly once. The Go
    /// engine's connection listener reports every management/signal reconnect as a fresh
    /// onConnected, so the adapter's start callback fires repeatedly over one tunnel's life;
    /// this latch keeps the first outcome and drops the rest. Locked because the outcome can
    /// arrive on the main queue (connection listener) or a global queue (adapter start
    /// errors).
    private let startCompletionLock = NSLock()
    private var startCompletionHandler: ((Error?) -> Void)?

    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        armTunnelStartCompletion(completionHandler)

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

        monitorQueue.async { [weak self] in
            guard let self = self else { return }
            self.currentNetworkType = nil
            self.wasStoppedDueToNoNetwork = false
            self.isRestartInProgress = false
            self.networkChangeWorkItem?.cancel()
            self.networkChangeWorkItem = nil
            self.networkLossWorkItem?.cancel()
            self.networkLossWorkItem = nil
            self.adapter?.isNetworkUnavailable = false
            self.beginInitialStart()
            self.startMonitoringNetworkChanges()
        }

        guard let adapter = adapter else {
            let error = NSError(
                domain: "io.netbird.NetbirdNetworkExtension",
                code: 1003,
                userInfo: [NSLocalizedDescriptionKey: "Failed to initialize NetBird adapter."]
            )
            completeTunnelStart(with: error)
            return
        }

        // Skip this check when the main app has already established the login state (its own
        // isLoginRequired() call, or a login it just completed) and said so via the start
        // options. needsLogin() is a full Login RPC against the management server, so the
        // unconditional check duplicated one the other process had just made. Starts the main
        // app did not initiate (On Demand, widget intent) carry no flag and still verify here.
        // Either way an expired session is caught by the engine: its own login fails with
        // PermissionDenied, which drives onLoginRequired and tears the tunnel down.
        #if os(iOS)
        let loginVerifiedByApp = (options?[GlobalConstants.optionLoginVerified] as? NSNumber)?.boolValue ?? false
        #else
        let loginVerifiedByApp = false
        #endif
        if loginVerifiedByApp {
            AppLogger.shared.log("startTunnel: login already verified by the main app, skipping needsLogin check")
        }
        if !loginVerifiedByApp, adapter.needsLogin() {
            signalLoginRequired()
            // Clear any transitioning widget state so the login button appears immediately
            // instead of waiting for the snap-back window to expire.
            updateWidgetStatus("disconnected")
            // Return the error immediately so iOS tears down the tunnel interface at once.
            // A deferred completionHandler keeps the tunnel interface alive (black-hole state)
            // and intercepts all network traffic — including ASWebAuthenticationSession requests
            // to the OAuth server — causing "Page not found" during re-auth with On Demand enabled.
            completeTunnelStart(with: NSError(
                domain: "io.netbird.NetbirdNetworkExtension",
                code: 1001,
                userInfo: [NSLocalizedDescriptionKey: "Login required."]
            ))
            return
        }

        // Wire up the login-required callback so the connection listener can tear the
        // tunnel down if the auth session expires mid-session (token expires while the
        // VPN is running). On Android the kernel removes the VPN routes automatically
        // when the Go engine closes the TUN fd; on iOS the utun interface is owned by
        // the provider and outlives the Go engine, so without an explicit teardown it
        // lingers with the default route and black-holes all traffic until the user
        // opens the app. cancelTunnelWithError restores the default route immediately.
        adapter.onLoginRequired = { [weak self] in
            AppLogger.shared.log("onLoginRequired: session expired mid-tunnel — tearing down")
            self?.signalLoginRequired()
            self?.updateWidgetStatus("disconnected")
            self?.cancelTunnelWithError(NSError(
                domain: "io.netbird.NetbirdNetworkExtension",
                code: 1001,
                userInfo: [NSLocalizedDescriptionKey: "Login required."]
            ))
        }

        adapter.start { [weak self] error in
            if self?.completeTunnelStart(with: error) == false {
                AppLogger.shared.log("startTunnel: engine reported connected again, start outcome stays as first reported")
            }
            self?.monitorQueue.async {
                self?.endInitialStart()
            }
            if error == nil {
                self?.updateWidgetStatus("connected")
            } else {
                self?.updateWidgetStatus("disconnected")
            }
        }
    }

    /// Records the handler NE is waiting on for this tunnel session.
    private func armTunnelStartCompletion(_ handler: @escaping (Error?) -> Void) {
        startCompletionLock.lock()
        let pending = startCompletionHandler != nil
        startCompletionHandler = handler
        startCompletionLock.unlock()

        if pending {
            AppLogger.shared.log("armTunnelStartCompletion: replacing a start outcome that was never reported")
        }
    }

    /// Reports the tunnel's start outcome to NE, at most once per startTunnel.
    /// Returns true when this call is the one that delivered it.
    @discardableResult
    private func completeTunnelStart(with error: Error?) -> Bool {
        startCompletionLock.lock()
        let handler = startCompletionHandler
        startCompletionHandler = nil
        startCompletionLock.unlock()

        guard let handler = handler else { return false }
        handler(error)
        return true
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        // A stop that lands before the engine ever reported connected would otherwise leave
        // NE waiting on the start outcome forever: the outcome is delivered from the
        // connection listener's onConnected, and stopping just makes the engine's run loop
        // return without connecting — nothing calls it. Close it out here, bound to the end
        // of the start attempt rather than to its success. Latched, so a start that already
        // reported is untouched.
        let stoppedBeforeConnect = completeTunnelStart(with: NSError(
            domain: "io.netbird.NetbirdNetworkExtension",
            code: 1005,
            userInfo: [NSLocalizedDescriptionKey: "Tunnel stopped before the connection was established (reason \(reason.rawValue))."]
        ))
        if stoppedBeforeConnect {
            AppLogger.shared.log("stopTunnel: stopped before the connection was established, reported the start failure to NE")
        }

        monitorQueue.async { [weak self] in
            guard let self = self else { return }
            self.networkChangeWorkItem?.cancel()
            self.networkChangeWorkItem = nil
            self.networkLossWorkItem?.cancel()
            self.networkLossWorkItem = nil
            self.endInitialStart()
            self.currentNetworkType = nil
            self.wasStoppedDueToNoNetwork = false
            self.isRestartInProgress = false
        }
        // Reset network unavailable flag when tunnel stops
        adapter?.isNetworkUnavailable = false
        setNetworkUnavailableFlag(false)
        adapter?.stop()
        updateWidgetStatus("disconnected")
        stopMonitoringNetworkChanges()
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

    /// Starts monitoring the physical network. Must run on `monitorQueue`.
    ///
    /// The provider's own tunnel interface is excluded. An unfiltered path also covers the
    /// utun this provider creates, so every `setTunnelNetworkSettings` call — several per
    /// connect — flapped the monitored path. `handleNetworkChange` read that as an outage
    /// followed by a recovery and answered it with a client restart, which re-applied the
    /// settings and flapped the path again: a loop that kept the tunnel cycling until the
    /// timing happened to miss the detection window.
    func startMonitoringNetworkChanges() {
        // Only one monitor may be live. A second startTunnel in the same extension process
        // (On Demand re-trigger, widget start after a failed attempt) would otherwise leave
        // the previous monitor running, and both would handle every path update.
        pathMonitor?.cancel()

        let monitor = NWPathMonitor(prohibitedInterfaceTypes: [.other])
        monitor.pathUpdateHandler = { [weak self] path in
            self?.handleNetworkChange(path: path)
        }
        monitor.start(queue: monitorQueue)

        pathMonitor = monitor
    }

    /// Tears the path monitor down on the queue that starts it and handles its updates, so
    /// cancellation cannot race an in-flight path update.
    private func stopMonitoringNetworkChanges() {
        monitorQueue.async { [weak self] in
            guard let self = self else { return }
            guard let monitor = self.pathMonitor else {
                AppLogger.shared.log("stopMonitoringNetworkChanges: no monitor to cancel")
                return
            }
            monitor.cancel()
            self.pathMonitor = nil
        }
    }

    /// Arms the guard that keeps a network-change restart from tearing down a connection that
    /// is still coming up. Must run on `monitorQueue`.
    private func beginInitialStart() {
        initialStartTimeoutWorkItem?.cancel()
        isInitialStartInFlight = true

        let timeout = DispatchWorkItem { [weak self] in
            guard let self = self, self.isInitialStartInFlight else { return }
            AppLogger.shared.log("beginInitialStart: timeout - releasing the initial start guard")
            self.isInitialStartInFlight = false
            self.initialStartTimeoutWorkItem = nil
        }
        initialStartTimeoutWorkItem = timeout
        monitorQueue.asyncAfter(deadline: .now() + Self.initialStartGuardTimeout, execute: timeout)
    }

    /// Releases the initial-start guard. Must run on `monitorQueue`.
    private func endInitialStart() {
        initialStartTimeoutWorkItem?.cancel()
        initialStartTimeoutWorkItem = nil
        isInitialStartInFlight = false
    }

    /// Declares the network unavailable only once the path has stayed unsatisfied for
    /// `networkLossDebounce`. Must run on `monitorQueue`.
    ///
    /// We don't call adapter.stop() here to avoid race conditions with Go SDK callbacks —
    /// the Go SDK handles network loss internally and reconnects when the network is back.
    /// The flag only signals the UI so it can show the disconnecting animation.
    private func scheduleNetworkLossIfSustained() {
        guard !wasStoppedDueToNoNetwork, networkLossWorkItem == nil else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, !self.wasStoppedDueToNoNetwork else { return }
            self.networkLossWorkItem = nil

            let stateDesc = self.adapter?.clientState.description ?? "unknown"
            AppLogger.shared.log("Network unavailable - signaling UI for disconnecting animation, clientState=\(stateDesc)")
            self.wasStoppedDueToNoNetwork = true
            self.adapter?.isNetworkUnavailable = true
            self.setNetworkUnavailableFlag(true)
        }

        networkLossWorkItem = workItem
        monitorQueue.asyncAfter(deadline: .now() + Self.networkLossDebounce, execute: workItem)
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
            AppLogger.shared.log("Path not satisfied - confirming over \(Self.networkLossDebounce)s before treating it as an outage")

            // Cancel any pending restart
            networkChangeWorkItem?.cancel()
            networkChangeWorkItem = nil

            scheduleNetworkLossIfSustained()
            return
        }

        // Network is available again. A loss that never lasted long enough to be confirmed is
        // a blip: drop it so it produces neither the UI's network warning nor a restart.
        networkLossWorkItem?.cancel()
        networkLossWorkItem = nil

        let shouldRestartDueToRecovery = wasStoppedDueToNoNetwork
        if wasStoppedDueToNoNetwork {
            AppLogger.shared.log("Network restored after unavailability - signaling UI")
            wasStoppedDueToNoNetwork = false
            adapter?.isNetworkUnavailable = false
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

        // Check if network type changed (only if both current and new types are known)
        let networkTypeChanged: Bool
        if let current = currentNetworkType, let newType = newNetworkType {
            networkTypeChanged = current != newType
        } else {
            networkTypeChanged = false
        }

        if networkTypeChanged {
            AppLogger.shared.log("Network type changed: \(String(describing: currentNetworkType)) -> \(String(describing: newNetworkType))")
        }

        // Restart if network type changed OR recovering from network unavailability
        // (even if returning to the same interface type, the connection may be stale)
        // This must happen regardless of network type (wifi/cellular/other)
        if networkTypeChanged || shouldRestartDueToRecovery {
            AppLogger.shared.log("Scheduling restart: networkTypeChanged=\(networkTypeChanged), shouldRestartDueToRecovery=\(shouldRestartDueToRecovery)")

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

        // Update current network type only if known
        if let newType = newNetworkType {
            currentNetworkType = newType
        }
    }

    func restartClient() {
        guard let adapter = adapter else {
            AppLogger.shared.log("restartClient: adapter is nil")
            return
        }

        if isInitialStartInFlight {
            AppLogger.shared.log("restartClient: skipping - initial connection still in flight")
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
            AppLogger.shared.log("restartClient: stop completed, checking login status")

            // Tokens may have expired during a network change (common with self-hosted servers
            // that have shorter token lifetimes). Check before restarting; if login is required
            // signal the main app so it can show the re-auth UI instead of silently failing.
            // The cached check reads the auth state the engine already recorded, so a network
            // change no longer costs a Login RPC. An expiry the recorder has not seen yet is
            // still caught one step later: the restarted engine's own login fails with
            // PermissionDenied and drives onLoginRequired from the connection listener.
            if self?.adapter?.needsLoginCached() == true {
                AppLogger.shared.log("restartClient: login required — signaling main app, skipping restart")
                self?.signalLoginRequired()
                self?.updateWidgetStatus("disconnected")
                self?.monitorQueue.async {
                    self?.adapter?.isRestarting = false
                    self?.isRestartInProgress = false
                }
                timeoutWorkItem.cancel()
                return
            }

            AppLogger.shared.log("restartClient: starting client")
            self?.adapter?.start { [weak self] error in
                // Cancel timeout whether start succeeds or not
                timeoutWorkItem.cancel()

                self?.monitorQueue.async {
                    self?.adapter?.isRestarting = false
                    self?.isRestartInProgress = false
                }

                if let error = error {
                    AppLogger.shared.log("restartClient: start failed - \(error.localizedDescription)")
                    // If the start failed because the session expired, the connection
                    // listener may have suppressed its login-required signalling: it skips
                    // both checks while isRestarting is still true, which happens when the
                    // stop phase never fired onDisconnected (engine already dead) and the
                    // stop completion arrived via the 15s fallback instead. Re-check the
                    // recorder here — the engine marks it with PermissionDenied before
                    // Run() returns — and signal + tear down so the dead tunnel doesn't
                    // linger and black-hole traffic.
                    if self?.adapter?.needsLoginCached() == true {
                        AppLogger.shared.log("restartClient: start failed due to expired login — signaling and tearing down")
                        self?.signalLoginRequired()
                        self?.cancelTunnelWithError(NSError(
                            domain: "io.netbird.NetbirdNetworkExtension",
                            code: 1001,
                            userInfo: [NSLocalizedDescriptionKey: "Login required."]
                        ))
                    }
                    self?.updateWidgetStatus("disconnected")
                } else {
                    AppLogger.shared.log("restartClient: start completed successfully")
                    self?.updateWidgetStatus("connected")
                }
            }
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
