//
//  PacketTunnelProvider.swift
//  NetBirdTVNetworkExtension
//
//  Created by Ashley Mensah on 02.12.25.
//

import NetworkExtension
import Network
import os
import NetBirdSDK

private let logger = Logger(subsystem: "io.netbird.app.tv.extension", category: "PacketTunnelProvider")

// SSO Listener for config initialization
/// Used by initializeConfig to check if SSO is supported and save initial config
class ConfigInitSSOListener: NSObject, NetBirdSDKSSOListenerProtocol {
    var onResult: ((Bool?, Error?) -> Void)?

    func onSuccess(_ ssoSupported: Bool) {
        onResult?(ssoSupported, nil)
    }

    func onError(_ error: Error?) {
        onResult?(nil, error)
    }
}

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
        // CRITICAL: Log immediately to confirm startTunnel is being called
        // Use privacy: .public to avoid log redaction
        logger.info(">>> startTunnel: ENTRY - function was called <<<")
        NSLog("NetBirdTV: startTunnel ENTRY - function was called")

        let optionsDesc = options?.description ?? "nil"
        logger.info("startTunnel: options = \(optionsDesc, privacy: .public)")

        // Skip file-based logging on tvOS - it will fail due to sandbox
        #if !os(tvOS)
        if let options = options, let logLevel = options["logLevel"] as? String {
            logger.info("startTunnel: initializing logging with level \(logLevel, privacy: .public)")
            initializeLogging(loglevel: logLevel)
        }
        #else
        logger.info("startTunnel: skipping file-based logging on tvOS (sandbox blocks writes)")
        NSLog("NetBirdTV: skipping file-based logging on tvOS")

        // CRITICAL: On tvOS, restore config from UserDefaults to file BEFORE the adapter is created.
        // The lazy adapter creates NetBirdSDKNewClient() which reads from the config file path.
        // If we don't restore the file first, the Client will be initialized with empty/missing config.
        // This must happen BEFORE any access to `adapter` property.
        if Preferences.hasConfigInUserDefaults() {
            logger.info("startTunnel: tvOS - restoring config from UserDefaults to file BEFORE adapter init")
            NSLog("NetBirdTV: restoring config from UserDefaults to file BEFORE adapter init")
            if Preferences.restoreConfigFromUserDefaults() {
                logger.info("startTunnel: tvOS - config file restored successfully")
                NSLog("NetBirdTV: config file restored successfully")
            } else {
                logger.warning("startTunnel: tvOS - failed to restore config file, adapter may not work correctly")
                NSLog("NetBirdTV: WARNING - failed to restore config file")
            }
        }
        #endif

        currentNetworkType = nil
        startMonitoringNetworkChanges()

        // Initialize config if it doesn't exist (tvOS only)
        initializeConfigIfNeeded()

        let needsLogin = adapter.needsLogin()

        if needsLogin {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                let error = NSError(
                    domain: "io.netbird.NetBirdTVNetworkExtension",
                    code: 1001,
                    userInfo: [NSLocalizedDescriptionKey: "Login required."]
                )
                completionHandler(error)
            }
            return
        }

        adapter.start { [self] error in
            if let error = error {
                logger.error("startTunnel: adapter.start() failed: \(error.localizedDescription, privacy: .public)")
                completionHandler(error)
            } else {
                completionHandler(nil)
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        adapter.stop()
        if let pathMonitor = self.pathMonitor {
            pathMonitor.cancel()
            self.pathMonitor = nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            completionHandler()
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let completionHandler = completionHandler,
              let string = String(data: messageData, encoding: .utf8) else {
            return
        }

        // Use privacy: .public to see the actual message in Console.app
        logger.info("handleAppMessage: Received message '\(string, privacy: .public)'")

        switch string {
        case "InitializeConfig":
            // Initialize config with default management URL (tvOS only)
            // This must happen in the extension because it has permission to write to App Group
            initializeConfig(completionHandler: completionHandler)
        case "Login":
            // Legacy login (PKCE flow)
            login(completionHandler: completionHandler)
        case "LoginTV":
            // tvOS login with device code flow
            logger.info("handleAppMessage: Processing LoginTV - calling loginTV()")
            loginTV(completionHandler: completionHandler)
        case "IsLoginComplete":
            // Check if login has completed (for tvOS polling)
            checkLoginComplete(completionHandler: completionHandler)
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
            logger.warning("handleAppMessage: Unknown message: \(string)")
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
        guard path.status == .satisfied else {
            logger.info("handleNetworkChange: No network connection.")
            return
        }

        let newNetworkType: NWInterface.InterfaceType? = {
            if path.usesInterfaceType(.wifi) {
                return .wifi
            } else if path.usesInterfaceType(.wiredEthernet) {
                return .wiredEthernet
            } else {
                return nil
            }
        }()

        guard let networkType = newNetworkType else {
            logger.info("handleNetworkChange: Connected to an unsupported network type.")
            return
        }

        if currentNetworkType != networkType {
            logger.info("handleNetworkChange: Network type changed to \(String(describing: networkType)).")
            if currentNetworkType != nil {
                restartClient()
            }
            currentNetworkType = networkType
        } else {
            logger.debug("handleNetworkChange: Network type remains the same: \(String(describing: networkType)).")
        }
    }

    func restartClient() {
        logger.info("restartClient: Restarting client due to network change")
        adapter.stop()
        adapter.start { [self] error in
            if let error = error {
                logger.error("restartClient: Error restarting client: \(error.localizedDescription)")
            } else {
                logger.info("restartClient: Client restarted successfully")
            }
        }
    }

    func login(completionHandler: (Data?) -> Void) {
        logger.info("login: Starting PKCE login flow")
        let urlString = adapter.login()
        let data = urlString.data(using: .utf8)
        completionHandler(data)
    }

    /// Initialize config with default management URL for tvOS
    /// This must be done in the extension because it has permission to write to the App Group container
    func initializeConfig(completionHandler: @escaping (Data?) -> Void) {
        let configPath = Preferences.configFile()
        let fileManager = FileManager.default

        // Check if config already exists
        if fileManager.fileExists(atPath: configPath) {
            logger.info("initializeConfig: Config already exists at \(configPath)")
            let data = "true".data(using: .utf8)
            completionHandler(data)
            return
        }

        logger.info("initializeConfig: No config found, initializing with default management URL")

        // Create Auth object with default management URL
        guard let auth = NetBirdSDKNewAuth(configPath, NetBirdAdapter.defaultManagementURL, nil) else {
            logger.error("initializeConfig: Failed to create Auth object")
            let data = "false".data(using: .utf8)
            completionHandler(data)
            return
        }

        // Use an SSO listener to save the config
        let listener = ConfigInitSSOListener()
        listener.onResult = { [self] ssoSupported, error in
            if let error = error {
                logger.error("initializeConfig: Error checking SSO - \(error.localizedDescription)")
                let data = "false".data(using: .utf8)
                completionHandler(data)
            } else if let supported = ssoSupported {
                logger.info("initializeConfig: SSO supported = \(supported), config should be saved")
                // Verify config was written
                let configExists = fileManager.fileExists(atPath: configPath)
                logger.info("initializeConfig: Config exists after save = \(configExists)")
                let data = configExists ? "true".data(using: .utf8) : "false".data(using: .utf8)
                completionHandler(data)
            } else {
                logger.warning("initializeConfig: Unknown result")
                let data = "false".data(using: .utf8)
                completionHandler(data)
            }
        }

        // This will save the config if SSO is supported
        auth.saveConfigIfSSOSupported(listener)
    }

    /// Initialize config synchronously during startTunnel
    /// On tvOS, config is loaded from UserDefaults directly into memory (file writes are blocked)
    private func initializeConfigIfNeeded() {
        let configPath = Preferences.configFile()
        let fileManager = FileManager.default

        // Check if config already exists as a file
        if fileManager.fileExists(atPath: configPath) {
            return
        }

        // On tvOS, try to load config from UserDefaults directly into memory
        if Preferences.hasConfigInUserDefaults() {
            if var configJSON = Preferences.loadConfigFromUserDefaults() {
                // Update the device name in config before loading
                let correctDeviceName = Device.getName()
                configJSON = NetBirdAdapter.updateDeviceNameInConfig(configJSON, newName: correctDeviceName)

                do {
                    try adapter.client.setConfigFromJSON(configJSON)
                    return
                } catch {
                    #if os(tvOS)
                    return
                    #endif
                }
            }
        }

        #if os(tvOS)
        // On tvOS, if we get here without config, user needs to authenticate first
        #else
        // On iOS, try to create config via file writes
        guard let auth = NetBirdSDKNewAuth(configPath, NetBirdAdapter.defaultManagementURL, nil) else {
            return
        }

        let semaphore = DispatchSemaphore(value: 0)

        let listener = ConfigInitSSOListener()
        listener.onResult = { _, _ in
            semaphore.signal()
        }

        auth.saveConfigIfSSOSupported(listener)

        _ = semaphore.wait(timeout: .now() + 10)
        #endif
    }

    /// Check if login has completed (for tvOS polling during device auth flow)
    /// Returns diagnostic info: "result|isExecuting|loginRequired|configExists|stateExists|lastResult|lastError"
    func checkLoginComplete(completionHandler: (Data?) -> Void) {
        // Check if login is still in progress
        let isExecutingLogin = adapter.isExecutingLogin

        // Note: client.isLoginComplete() only works with the legacy LoginForMobile() method.
        // For the new Auth.Login() with device auth flow, we need to check lastLoginResult instead.
        let sdkLoginComplete = adapter.client.isLoginComplete()

        // Also check loginRequired for comparison (may be stale if Client was created before config)
        let loginRequired = adapter.needsLogin()

        // Also check if config file exists now (written after successful auth)
        let configPath = Preferences.configFile()
        let statePath = Preferences.stateFile()
        let fileManager = FileManager.default
        let configExists = fileManager.fileExists(atPath: configPath)
        let stateExists = fileManager.fileExists(atPath: statePath)

        // Get the last login result and error
        let lastResult = adapter.lastLoginResult
        let lastError = adapter.lastLoginError

        logger.info("checkLoginComplete: isExecutingLogin=\(isExecutingLogin), sdkLoginComplete=\(sdkLoginComplete), loginRequired=\(loginRequired), configExists=\(configExists), stateExists=\(stateExists), lastResult=\(lastResult), lastError=\(lastError)")

        // IMPORTANT: client.isLoginComplete() does NOT work with Auth.Login() / loginAsync()
        // because Auth is a separate struct that doesn't have access to Client.loginComplete.
        // Instead, use lastLoginResult which IS set by loginAsync() when auth succeeds.
        let isComplete = (lastResult == "success")

        // Return diagnostic info in format: "result|isExecuting|loginRequired|configExists|stateExists|lastResult|lastError"
        let response = "\(isComplete)|\(isExecutingLogin)|\(loginRequired)|\(configExists)|\(stateExists)|\(lastResult)|\(lastError)"
        logger.info("checkLoginComplete: returning \(response)")
        let data = response.data(using: .utf8)
        completionHandler(data)
    }

    /// Login with device code flow for tvOS
    /// Returns "url|userCode" format so the app can display both
    /// The app is responsible for starting the VPN after login completes
    func loginTV(completionHandler: @escaping (Data?) -> Void) {
        logger.info("loginTV: Starting device code authentication flow")

        // Initialize config file BEFORE attempting login
        // This ensures the Auth object has a valid config to save credentials to
        initializeConfigIfNeeded()

        // Verify config was created
        let configPath = Preferences.configFile()
        let configExists = FileManager.default.fileExists(atPath: configPath)
        logger.info("loginTV: After initializeConfigIfNeeded, configExists=\(configExists), path=\(configPath)")

        // Track if we've already sent the URL to the app
        var urlSentToApp = false
        let urlSentLock = NSLock()

        logger.info("loginTV: Calling adapter.loginAsync with forceDeviceAuth=true")

        adapter.loginAsync(
            forceDeviceAuth: true,
            onURL: { [self] url, userCode in
                // Return URL and user code in pipe-separated format
                logger.info("loginTV: onURL callback triggered!")
                logger.info("loginTV: Received URL and userCode, sending to app")
                logger.info("loginTV: URL=\(url, privacy: .public), userCode=\(userCode, privacy: .public)")

                urlSentLock.lock()
                urlSentToApp = true
                urlSentLock.unlock()

                let response = "\(url)|\(userCode)"
                let data = response.data(using: .utf8)
                completionHandler(data)
            },
            onSuccess: { [self] in
                // Login completed - the app will detect this via polling
                // and start the VPN tunnel via startVPNConnection()
                logger.info("loginTV: Login completed successfully!")
                logger.info("loginTV: Config should now be saved to App Group container")

                // Debug: Verify config file was written
                let configPath = Preferences.configFile()
                let statePath = Preferences.stateFile()
                let fileManager = FileManager.default
                logger.info("loginTV: configFile exists = \(fileManager.fileExists(atPath: configPath))")
                logger.info("loginTV: stateFile exists = \(fileManager.fileExists(atPath: statePath))")
            },
            onError: { [self] error in
                // Log with privacy: .public to avoid iOS privacy redaction
                if let nsError = error as NSError? {
                    logger.error("loginTV: Login failed - domain: \(nsError.domain, privacy: .public), code: \(nsError.code, privacy: .public), description: \(nsError.localizedDescription, privacy: .public)")
                    if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
                        logger.error("loginTV: Underlying error: \(String(describing: underlyingError), privacy: .public)")
                    }
                } else {
                    logger.error("loginTV: Login failed: \(error?.localizedDescription ?? "unknown error", privacy: .public)")
                }

                // Only call completion with nil if we never sent the URL
                // If URL was sent, the error just means the user didn't complete auth yet
                // (e.g., device code expired) - but we already returned control to the app
                urlSentLock.lock()
                let alreadySentUrl = urlSentToApp
                urlSentLock.unlock()

                if !alreadySentUrl {
                    logger.error("loginTV: Error before URL was sent, returning nil to app")
                    completionHandler(nil)
                } else {
                    logger.warning("loginTV: Error after URL was sent (device code may have expired), app is still polling")
                }
            }
        )
    }

    func getStatus(completionHandler: (Data?) -> Void) {
        guard let statusDetailsMessage = adapter.client.getStatusDetails() else {
            logger.warning("getStatus: Did not receive status details.")
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
            logger.error("getStatus: Failed to encode status details: \(error.localizedDescription)")
            do {
                let defaultStatus = StatusDetails(ip: "", fqdn: "", managementStatus: adapter.clientState, peerInfo: [])
                let data = try PropertyListEncoder().encode(defaultStatus)
                completionHandler(data)
            } catch {
                logger.error("getStatus: Failed to encode default status: \(error.localizedDescription)")
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
            logger.error("getSelectRoutes: Error retrieving or encoding route selection details: \(error.localizedDescription)")
            let defaultStatus = RoutesSelectionDetails(all: false, append: false, routeSelectionInfo: [])
            do {
                let data = try PropertyListEncoder().encode(defaultStatus)
                completionHandler(data)
            } catch {
                logger.error("getSelectRoutes: Failed to encode default route selection details: \(error.localizedDescription)")
                completionHandler(nil)
            }
        }
    }

    func selectRoute(id: String) {
        do {
            try adapter.client.selectRoute(id)
            logger.info("selectRoute: Selected route \(id)")
        } catch {
            logger.error("selectRoute: Failed to select route: \(error.localizedDescription)")
        }
    }

    func deselectRoute(id: String) {
        do {
            try adapter.client.deselectRoute(id)
            logger.info("deselectRoute: Deselected route \(id)")
        } catch {
            logger.error("deselectRoute: Failed to deselect route: \(error.localizedDescription)")
        }
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    override func wake() {
    }

    func setTunnelSettings(tunnelNetworkSettings: NEPacketTunnelNetworkSettings) {
        setTunnelNetworkSettings(tunnelNetworkSettings) { [self] error in
            if let error = error {
                logger.error("setTunnelSettings: Error assigning routes: \(error.localizedDescription)")
                return
            }
            logger.info("setTunnelSettings: Routes set successfully.")
        }
    }
}

func initializeLogging(loglevel: String) {
    let fileManager = FileManager.default

    let groupURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: Preferences.appGroupIdentifier)
    let logURL = groupURL?.appendingPathComponent("logfile.log")

    var error: NSError?
    var success = false

    let logMessage = "Starting new log file from TV extension" + "\n"

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