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

    private var networkChangeWorkItem: DispatchWorkItem?

    /// Observer token for UserDefaults.didChangeNotification — used to
    /// catch MDM managed-configuration pushes
    /// (UserDefaults["com.apple.configuration.managed"]) and trigger an
    /// engine restart so the new policy values flow through
    /// Config.apply → applyMDMPolicy on the next Run.
    private var mdmConfigObserver: NSObjectProtocol?

    /// Set when a policy change arrived while a restart was already in
    /// flight. Go's detector records the newer policy the moment it is
    /// observed, so it will not report the change again - if this restart
    /// were simply dropped, that policy would never be applied. The flag
    /// makes the handler come back for it.
    private var pendingMDMRestart = false

    /// The deferred retry that waits out an in-flight restart. Tracked so
    /// teardown can cancel it: otherwise it fires afterwards, passes a guard
    /// that stopTunnel has just reset, and calls adapter.start() on a tunnel
    /// that is going away.
    private var mdmRetryWorkItem: DispatchWorkItem?

    /// Set once stopTunnel begins, so anything still in flight can tell that
    /// starting the client is no longer wanted.
    ///
    /// Lock-guarded rather than confined to monitorQueue: adapter.stop() can
    /// run an existing stop handler synchronously, and the restart pipeline's
    /// completions arrive on a global queue, so both the write and the reads
    /// happen off that queue. Queueing the write would let a reader see the
    /// stale value and start the engine into a teardown.
    private let tearDownLock = NSLock()
    private var _isTearingDown = false
    private var isTearingDown: Bool {
        get {
            tearDownLock.lock()
            defer { tearDownLock.unlock() }
            return _isTearingDown
        }
        set {
            tearDownLock.lock()
            _isTearingDown = newValue
            tearDownLock.unlock()
        }
    }

    /// Bumped by every startTunnel, so work begun for one tunnel lifecycle can
    /// tell that it is finishing into another.
    ///
    /// The teardown latch alone is not enough: adapter.stop() cannot cancel a
    /// stop callback that is already executing, and a following startTunnel
    /// clears the latch — so a callback from the previous lifecycle would pass
    /// the check and start the engine, or report a policy applied, for the new
    /// one. The generation makes that callback identifiable as stale.
    private var _tunnelGeneration = 0

    /// Opens a new lifecycle: clears the latch and invalidates every callback
    /// still in flight from the previous one.
    private func beginTunnelGeneration() -> Int {
        tearDownLock.lock()
        defer { tearDownLock.unlock() }
        _isTearingDown = false
        _tunnelGeneration += 1
        return _tunnelGeneration
    }

    private var tunnelGeneration: Int {
        tearDownLock.lock()
        defer { tearDownLock.unlock() }
        return _tunnelGeneration
    }

    /// True from the moment startTunnel hands off to adapter.start until that
    /// call completes.
    ///
    /// Initial startup does not set isRestartInProgress, so without this an
    /// MDM restart arriving in that window would pass the guard and call
    /// adapter.stop() while client.run() was still being dispatched — the
    /// adapter does not serialise the two. Deferring instead of dropping means
    /// the policy is applied as soon as startup finishes.
    private var _isStartingTunnel = false
    private var isStartingTunnel: Bool {
        get {
            tearDownLock.lock()
            defer { tearDownLock.unlock() }
            return _isStartingTunnel
        }
        set {
            tearDownLock.lock()
            _isStartingTunnel = newValue
            tearDownLock.unlock()
        }
    }

    /// True only while `generation` is still the live lifecycle and no
    /// teardown has begun.
    private func isCurrentGeneration(_ generation: Int) -> Bool {
        tearDownLock.lock()
        defer { tearDownLock.unlock() }
        return !_isTearingDown && _tunnelGeneration == generation
    }

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

        monitorQueue.async { [weak self] in
            self?.currentNetworkType = nil
            self?.wasStoppedDueToNoNetwork = false
            self?.isRestartInProgress = false
            self?.adapter?.isNetworkUnavailable = false
            self?.startMonitoringNetworkChanges()
        }

        _ = beginTunnelGeneration()
        startObservingMDMConfigChanges()

        guard let adapter = adapter else {
            let error = NSError(
                domain: "io.netbird.NetbirdNetworkExtension",
                code: 1003,
                userInfo: [NSLocalizedDescriptionKey: "Failed to initialize NetBird adapter."]
            )
            completionHandler(error)
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
            completionHandler(NSError(
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

        isStartingTunnel = true
        adapter.start { [weak self] error in
            self?.isStartingTunnel = false
            completionHandler(error)
            if error == nil {
                self?.updateWidgetStatus("connected")
            } else {
                self?.updateWidgetStatus("disconnected")
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        // Synchronously, and before adapter.stop(): that call can invoke an
        // existing stop handler inline, which would otherwise read the old
        // value and restart into the teardown.
        isTearingDown = true
        isStartingTunnel = false
        monitorQueue.async { [weak self] in
            self?.networkChangeWorkItem?.cancel()
            self?.networkChangeWorkItem = nil
            self?.mdmRetryWorkItem?.cancel()
            self?.mdmRetryWorkItem = nil
            self?.pendingMDMRestart = false
            self?.currentNetworkType = nil
            self?.wasStoppedDueToNoNetwork = false
            self?.isRestartInProgress = false
        }
        stopObservingMDMConfigChanges()
        // Reset network unavailable flag when tunnel stops
        adapter?.isNetworkUnavailable = false
        setNetworkUnavailableFlag(false)
        adapter?.stop()
        updateWidgetStatus("disconnected")
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
                adapter?.isNetworkUnavailable = true
                setNetworkUnavailableFlag(true)
            }
            return
        }

        // Network is available again
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

    /// - Parameter onRestarted: run only when the engine is back up. Callers
    ///   that must not report success early — an applied MDM policy, say —
    ///   hang their side effect here rather than on the call returning, which
    ///   happens long before the restart finishes.
    func restartClient(onRestarted: (() -> Void)? = nil) {
        guard let adapter = adapter else {
            AppLogger.shared.log("restartClient: adapter is nil")
            return
        }

        if isRestartInProgress {
            AppLogger.shared.log("restartClient: skipping - restart already in progress")
            return
        }
        AppLogger.shared.log("restartClient: starting restart sequence")
        let generation = tunnelGeneration
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

            // stopTunnel may have begun while this pipeline sat in its stop
            // phase. The scheduling-time guard cannot see that, and cancelling
            // the retry work item cannot stop work already past it — so check
            // again here, immediately before bringing the engine back up.
            if let self = self, !self.isCurrentGeneration(generation) {
                AppLogger.shared.log("restartClient: tunnel lifecycle moved on — abandoning restart")
                self.monitorQueue.async { [weak self] in
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
                    // A restart that finished into a teardown has not put any
                    // policy into force, so it must not report that it did.
                    if self?.isCurrentGeneration(generation) == true {
                        onRestarted?()
                    }
                    self?.updateWidgetStatus("connected")
                }
            }
        }
    }

    /// Signals that a policy change was applied, using the same two-path
    /// delivery as the login-required signal: a flag in the shared app-group
    /// container that the main app picks up when it becomes active, plus a
    /// best-effort local notification for the case where it does not.
    private func signalMDMPolicyApplied() {
        let userDefaults = UserDefaults(suiteName: GlobalConstants.userPreferencesSuiteName)
        userDefaults?.set(true, forKey: GlobalConstants.keyMDMPolicyApplied)
        userDefaults?.synchronize()

        let content = UNMutableNotificationContent()
        content.title = "MDM policy applied"
        content.body = "NetBird configuration was updated by your IT policy."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: GlobalConstants.notificationMDMPolicyApplied,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                AppLogger.shared.log("MDM: policy-applied notification not delivered from extension: \(error)")
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
        // adapter.start completions land on a global queue, so one can arrive
        // after stopTunnel has already written "disconnected". Guarding here
        // rather than at each call site covers startTunnel and every restart
        // path at once.
        if status == "connected", isTearingDown {
            AppLogger.shared.log("updateWidgetStatus: ignoring \"connected\" during teardown")
            return
        }
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

    // MARK: - MDM managed-configuration observer

    /// Subscribes to UserDefaults.didChangeNotification so changes to
    /// the OS-pushed MDM managed-config dictionary
    /// (UserDefaults["com.apple.configuration.managed"]) trigger an
    /// engine restart. iOS does NOT fire a dedicated MDM notification
    /// — the entire UserDefaults change channel is shared, so this
    /// fires on every unrelated preference write too. Deciding whether
    /// the policy actually changed is Go's job; see the handler.
    private func startObservingMDMConfigChanges() {
        if mdmConfigObserver != nil {
            return
        }
        mdmConfigObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.handleManagedConfigDidChangeIfRelevant()
        }
        AppLogger.shared.log("MDM: subscribed to managed-configuration changes")
    }

    private func stopObservingMDMConfigChanges() {
        if let token = mdmConfigObserver {
            NotificationCenter.default.removeObserver(token)
            mdmConfigObserver = nil
            AppLogger.shared.log("MDM: unsubscribed from managed-configuration changes")
        }
        pendingMDMRestart = false
    }

    /// Called from the UserDefaults notification. The dedup this shared
    /// channel needs lives in Go: hasMDMPolicyChanged() re-reads through
    /// the registered fetcher, diffs against its last observation, logs
    /// the per-key delta and returns true only on a real change. The
    /// detector is created by setMDMPolicyFetcher, so with no fetcher
    /// registered this is always false and nothing restarts.
    private func handleManagedConfigDidChangeIfRelevant() {
        guard let client = adapter?.client, client.hasMDMPolicyChanged() else {
            return
        }

        AppLogger.shared.log("MDM: managed configuration changed; restarting client")
        requestMDMRestart()
    }

    /// Drives the restart for a policy change, deferring around one already
    /// in flight.
    ///
    /// restartClient() returns immediately and does its work asynchronously,
    /// and it refuses to start while another restart runs. Calling it during
    /// one would therefore be a silent no-op for a policy Go has already
    /// marked as seen. Retry instead until the pipeline is free; its own
    /// 30-second timeout bounds the wait.
    private func requestMDMRestart() {
        // monitorQueue, not the main queue: the network-change path already
        // drives restartClient() from here, and isRestartInProgress is plain
        // shared state. Running the two on different queues lets both pass the
        // guard and start their own stop/start pipelines.
        monitorQueue.async { [weak self] in
            guard let self = self, !self.isTearingDown else { return }
            guard !self.isRestartInProgress, !self.isStartingTunnel else {
                self.pendingMDMRestart = true
                AppLogger.shared.log("MDM: a start or restart is in flight; will retry once it finishes")
                self.mdmRetryWorkItem?.cancel()
                let retry = DispatchWorkItem { [weak self] in
                    guard let self = self, self.pendingMDMRestart, !self.isTearingDown else { return }
                    self.requestMDMRestart()
                }
                self.mdmRetryWorkItem = retry
                self.monitorQueue.asyncAfter(deadline: .now() + 2, execute: retry)
                return
            }
            self.mdmRetryWorkItem = nil
            self.pendingMDMRestart = false
            // Only a restart that actually brought the engine back up means the
            // policy is in force; a deferred or failed one must not tell the
            // user otherwise.
            self.restartClient { [weak self] in
                self?.signalMDMPolicyApplied()
            }
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
