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
import Network
import NetBirdSDK
import os

// URL opener and error listener for main-app-side OAuth login.
// Running login in the main app avoids the NE extension's client context being
// cancelled (adapter.stop → client.stop kills the WaitToken goroutine before
// the HTTP server can receive the OAuth callback).
#if os(iOS)
private class MainAppLoginURLOpener: NSObject, NetBirdSDKURLOpenerProtocol {
    var onOpen: ((String, String) -> Void)?
    var onSuccess: (() -> Void)?
    func open(_ url: String?, userCode: String?) {
        guard let url else { return }
        onOpen?(url, userCode ?? "")
    }
    func onLoginSuccess() { onSuccess?() }
}

private class MainAppLoginErrListener: NSObject, NetBirdSDKErrListenerProtocol {
    var onSuccessCallback: (() -> Void)?
    var onErrorCallback: ((Error?) -> Void)?
    func onError(_ err: Error?) { onErrorCallback?(err) }
    func onSuccess() { onSuccessCallback?() }
}
#endif

// SSO Listener for config initialization
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

#if os(tvOS)
/// Thread-safe generation token for cancelling the delayed device-auth IPC retry chain.
private nonisolated final class LoginRetryState: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt = 0

    func begin() -> UInt {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        return generation
    }

    func isActive(_ candidate: UInt) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == candidate
    }

    func cancel() {
        lock.lock()
        generation &+= 1
        lock.unlock()
    }
}
#endif

public class NetworkExtensionAdapter: ObservableObject {

    private let logger = Logger(subsystem: "io.netbird.app", category: "NetworkExtensionAdapter")

    #if os(tvOS)
    static let defaultManagementURL = "https://api.netbird.io"
    #endif

    var session: NETunnelProviderSession?
    var vpnManager: NETunnelProviderManager?

    #if os(tvOS)
    var extensionID = "io.netbird.app.tv.extension"
    var extensionName = "NetBird"
    private let loginRetryState = LoginRetryState()
    #else
    var extensionID = "io.netbird.app.NetbirdNetworkExtension"
    var extensionName = "NetBird Network Extension"
    #endif

    let decoder = PropertyListDecoder()

    @Published var timer: Timer

    @Published var showBrowser = false
    @Published var loginURL: String?
    #if os(iOS)
    private var pendingAuth: NetBirdSDKAuth?
    /// Set to true by the SDK's onLoginSuccess callback, which fires only once the
    /// whole flow is done: authorization code exchanged AND the peer registered with
    /// the management server. The browser cannot report this — its completion looks
    /// the same whether the user cancelled or closed the SDK's success page — so
    /// every "did the login work" decision reads this flag.
    public private(set) var loginSucceeded = false
    /// Reason the last login failed, surfaced to the user. Nil when there is nothing
    /// to report.
    @Published public var loginErrorMessage: String?
    /// Incremented on every performLogin entry. Deferred work armed for one attempt
    /// captures the value and compares before acting, so a stale timer can never
    /// abort a newer attempt.
    public private(set) var loginAttemptToken = 0
    /// Authorization URL of the in-flight login, used to locate the SDK's loopback
    /// listener when deciding whether a closed browser means "cancelled".
    private var pendingAuthorizeURL: String?
    #endif
    @Published var userCode: String?

    private let fetchLock = NSLock()
    private var _isFetchingStatus = false
    private var isFetchingStatus: Bool {
        get { fetchLock.lock(); defer { fetchLock.unlock() }; return _isFetchingStatus }
        set { fetchLock.lock(); defer { fetchLock.unlock() }; _isFetchingStatus = newValue }
    }

    init() {
        self.timer = Timer()
        self.timer.invalidate()
        // Don't configure manager during init - it's a slow system call that blocks app startup.
        // Instead, configureManager is called lazily when needed (start(), stop(), etc.)
        // This allows the UI to appear immediately on first launch.
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
            #if os(iOS)
            // Restore the config file before login if it was deleted (e.g. after logout).
            // This must happen in the main app — not via IPC — because the extension
            // process may not be running yet when start() is called.
            restoreConfigIfMissing()
            #endif
            await loginIfRequired()
            logger.info("start: loginIfRequired() completed")
        } catch {
            logger.error("start: CAUGHT ERROR - \(error.localizedDescription)")
        }
        logger.info("start: EXIT")
    }

    #if os(iOS)
    /// If the active profile's config file is missing (deleted after logout) but we have
    /// a saved management URL, write a minimal config so the SDK uses the correct server
    /// instead of falling back to the default api.netbird.io.
    private func restoreConfigIfMissing() {
        guard let configPath = Preferences.configFile() else { return }
        guard !FileManager.default.fileExists(atPath: configPath) else { return }

        let activeID = ProfileManager.shared.getActiveProfileID()
        // managementURL(forID:) reads the profile config first (which survives
        // logout in the ID-based model) and falls back to the connection cache.
        guard let url = ProfileManager.shared.managementURL(forID: activeID), !url.isEmpty else {
            logger.info("restoreConfigIfMissing: no saved URL for '\(activeID)', will use default server")
            return
        }

        logger.info("restoreConfigIfMissing: writing minimal config for '\(activeID)' with URL '\(url)'")
        // The Go SDK serializes url.URL as a nested JSON object {Scheme, Host, Path, ...}.
        // Writing ManagementURL as a plain string causes Go's json.Unmarshal to fail silently,
        // leaving ManagementURL nil and falling back to the default api.netbird.io server.
        // We must write the same nested-object format that the Go SDK expects.
        guard let parsedURL = URL(string: url) else {
            logger.error("restoreConfigIfMissing: could not parse URL '\(url)'")
            return
        }
        let scheme = parsedURL.scheme ?? "https"
        // Go's url.URL.Host includes the port (e.g. "my.server.io:443")
        var goHost = parsedURL.host ?? ""
        if let port = parsedURL.port { goHost += ":\(port)" }
        let path = parsedURL.path

        // Escape values for safe embedding in JSON
        func jsonEscape(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
        }

        let minimalConfig = "{\"ManagementURL\":{\"Scheme\":\"\(jsonEscape(scheme))\",\"Host\":\"\(jsonEscape(goHost))\",\"Path\":\"\(jsonEscape(path))\"}}"
        do {
            try minimalConfig.write(toFile: configPath, atomically: true, encoding: .utf8)
            logger.info("restoreConfigIfMissing: config written successfully (Scheme=\(scheme) Host=\(goHost) Path=\(path))")
        } catch {
            logger.error("restoreConfigIfMissing: failed to write config – \(error.localizedDescription)")
        }
    }
    #endif

    private func configureManager() async throws {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()

        // The provider bundle ID is the stable identity. A matching display name may
        // belong to another installed flavor, such as App Store and development builds.
        // Leave foreign configurations untouched, including active connections. Exact
        // provider matching below prevents one build from binding to another's profile.
        if let manager = managers.first(where: {
            $0.localizedDescription == self.extensionName &&
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == self.extensionID
        }) {
            self.vpnManager = manager
            // Only write preferences when strictly necessary.
            // Calling saveToPreferences() on an already-configured manager triggers
            // NEVPNStatusDidChange notifications — including a transient .disconnecting —
            // that the polling timer picks up, producing the wrong UI sequence:
            // Connecting → Disconnecting → Connected.
            if !manager.isEnabled {
                manager.isEnabled = true
                try await manager.saveToPreferences()
                try await manager.loadFromPreferences()
            }
        } else {
            let newManager = createNewManager()
            try await newManager.saveToPreferences()
            try await newManager.loadFromPreferences()
            self.vpnManager = newManager
        }
        self.session = self.vpnManager?.connection as? NETunnelProviderSession
    }

    /// Loads an existing VPN manager from preferences and returns the current connection state.
    /// This is used on app startup to establish the session for status polling and get the
    /// initial connection state, without triggering VPN configuration or starting a connection.
    /// Returns the current VPN connection status if a manager was found, nil otherwise.
    @MainActor
    public func loadCurrentConnectionState() async -> NEVPNStatus? {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            guard let manager = managers.first(where: {
                $0.localizedDescription == self.extensionName &&
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == self.extensionID
            }) else {
                logger.info("loadCurrentConnectionState: No existing manager found")
                return nil
            }
            self.vpnManager = manager
            self.session = manager.connection as? NETunnelProviderSession
            var status = manager.connection.status
            // The cached NE status can be stale (.disconnected) immediately after app launch
            // even when the VPN is actually connected. Reload from preferences once more to
            // get the daemon-fresh status; this matches what the widget extension sees via the
            // callback-based loadAllFromPreferences API.
            if status == .disconnected || status == .invalid {
                try? await Task.sleep(nanoseconds: 200_000_000) // 200 ms
                let refreshed = try await NETunnelProviderManager.loadAllFromPreferences()
                if let fresh = refreshed.first(where: {
                    $0.localizedDescription == self.extensionName &&
                    ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == self.extensionID
                }) {
                    status = fresh.connection.status
                    self.vpnManager = fresh
                    self.session = fresh.connection as? NETunnelProviderSession
                }
            }
            logger.info("loadCurrentConnectionState: status=\(status.rawValue)")
            return status
        } catch {
            logger.error("loadCurrentConnectionState: Error: \(error.localizedDescription)")
            return nil
        }
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

            #if os(tvOS)
            // Stop the system from retry-looping the tunnel while the user works through the
            // device code flow — every unattended start would fail on "login required".
            // applyExtensionStatus re-arms On Demand once the tunnel is up again.
            // Await the save: the login starts a tunnel of its own, and a rule that is still
            // in force would race it with an unauthenticated start.
            if isOnDemandEnabled {
                logger.info("loginIfRequired: disarming On Demand for the duration of the login")
                let result = await withCheckedContinuation { (continuation: CheckedContinuation<OnDemandUpdate, Never>) in
                    setOnDemandEnabled(false) { continuation.resume(returning: $0) }
                }
                if case .failed(let error) = result {
                    logger.error("loginIfRequired: could not disarm On Demand: \(error?.localizedDescription ?? "unknown error")")
                }
            }
            #endif

            // Note: For tvOS, config initialization happens in the extension's startTunnel
            // before the needsLogin check. The extension has permission to write to App Group.
            await performLogin()

            #if os(iOS)
            // If performLogin() didn't open the browser, the IPC failed because the extension
            // is not running. Start the VPN connection anyway so the extension process starts,
            // detects login required, signals the main app via UserDefaults, and stays alive
            // long enough for the user to press Connect from the auth alert (which will retry
            // IPC to a still-alive extension and succeed).
            if !self.showBrowser {
                logger.info("loginIfRequired: IPC failed (extension not running), starting VPN to launch extension")
                startVPNConnection()
            }
            #endif
        } else {
            logger.info("loginIfRequired: login NOT required, calling startVPNConnection()")
            // isLoginRequired() above just answered this against the management server;
            // tell the extension so it doesn't repeat the same Login RPC.
            startVPNConnection(loginVerified: true)
        }

        logger.info("loginIfRequired: done")
    }

    #if os(tvOS)
    /// Try to initialize the config file from the main app.
    /// On tvOS, shared UserDefaults doesn't work, so we send config via IPC.
    /// Settings (Rosenpass, PreSharedKey) are already stored in the config JSON.
    private func initializeConfigFromApp() async {
        // Check if config exists in main app's UserDefaults
        // Note: Shared UserDefaults doesn't work on tvOS between app and extension,
        // but we can still use it to store config in the main app
        if let configJSON = Preferences.loadConfigFromUserDefaults(), !configJSON.isEmpty {
            logger.info("initializeConfigFromApp: Config exists in UserDefaults (\(configJSON.count) chars), sending to extension via IPC")

            // Check if session exists for IPC
            if self.session == nil {
                logger.error("initializeConfigFromApp: session is nil! IPC will fail. Config won't reach extension.")
            }

            // Send config to extension via IPC (settings are already in the JSON)
            await sendConfigToExtensionAsync(configJSON)

            // Also send the management URL separately — the config JSON from Go SDK
            // serializes ManagementURL as a nested object, not a plain string,
            // so regex extraction in the extension fails.
            if let managementURL = Preferences.loadManagementURL() {
                logger.info("initializeConfigFromApp: Sending management URL separately: \(managementURL, privacy: .public)")
                await sendManagementURLToExtensionAsync(managementURL)
            } else {
                logger.warning("initializeConfigFromApp: No separate management URL saved")
            }
            return
        }

        guard let configPath = Preferences.configFile() else {
            logger.error("initializeConfigFromApp: App group container unavailable")
            return
        }
        let fileManager = FileManager.default

        // Check if config already exists as a file (unlikely on tvOS but check anyway)
        if fileManager.fileExists(atPath: configPath) {
            logger.info("initializeConfigFromApp: Config already exists at \(configPath)")
            return
        }

        logger.info("initializeConfigFromApp: No config found, user needs to configure server first")
        // Don't automatically create config with default URL - user should go through ServerView
    }

    /// Async wrapper for sendConfigToExtension
    private func sendConfigToExtensionAsync(_ configJSON: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sendConfigToExtension(configJSON) { [weak self] success in
                self?.logger.info("sendConfigToExtensionAsync: IPC result = \(success)")
                continuation.resume()
            }
        }
    }

    /// Send the management URL to the extension separately via IPC.
    /// This is needed because the Go SDK config JSON serializes ManagementURL
    /// as a nested object, making regex extraction unreliable.
    private func sendManagementURLToExtensionAsync(_ url: String) async {
        guard let session = self.session else {
            logger.warning("sendManagementURLToExtensionAsync: No session available")
            return
        }

        let messageString = "SetManagementURL:\(url)"
        guard let messageData = messageString.data(using: .utf8) else { return }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            do {
                try session.sendProviderMessage(messageData) { [weak self] response in
                    let success = response.flatMap { String(data: $0, encoding: .utf8) } == "true"
                    self?.logger.info("sendManagementURLToExtensionAsync: result = \(success)")
                    continuation.resume()
                }
            } catch {
                self.logger.error("sendManagementURLToExtensionAsync: Failed: \(error.localizedDescription)")
                continuation.resume()
            }
        }
    }
    #endif
    
    public func isLoginRequired() -> Bool {
        guard let configPath = Preferences.configFile(), let statePath = Preferences.stateFile() else {
            logger.error("isLoginRequired: App group container unavailable - assuming login required")
            return true
        }
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
        guard let client = NetBirdSDKNewClient("", statePath, Preferences.cacheDirectory(), "", Device.getName(), Device.getOsVersion(), Device.getOsName(), nil, nil) else {
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
                logger.debug("isLoginRequired: configFile size = \(size) bytes")
            }
        }

        if stateExists {
            if let attrs = try? fileManager.attributesOfItem(atPath: statePath),
               let size = attrs[.size] as? Int64 {
                logger.debug("isLoginRequired: stateFile size = \(size) bytes")
            }
        }

        guard let client = NetBirdSDKNewClient(configPath, statePath, Preferences.cacheDirectory(), "", Device.getName(), Device.getOsVersion(), Device.getOsName(), nil, nil) else {
            logger.debug("isLoginRequired: Failed to initialize client")
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
        #if os(iOS)
        // Run the OAuth flow in the main-app process using NetBirdSDKAuth.
        // The NE extension's client context is cancelled when adapter.stop() is called
        // (after startTunnel fails with login-required), which kills the WaitToken
        // goroutine before the HTTP server can receive the OAuth callback.
        // Running it here keeps the HTTP server alive for the full browser session.
        // NetBirdSDKNewAuth loads the existing config file at configPath when one is
        // present, so an interactive re-login reuses the peer's persisted WireGuard
        // private key (its identity) instead of generating a fresh one. A fresh key
        // would register a brand-new peer on the management server on every re-auth
        // (named after the fallback hostname). Only a first-time login with no config
        // yet builds a new in-memory config from the URL argument.
        // The second argument is the management URL: passing "" makes the Go SDK fall
        // back to the default cloud server (api.netbird.io), so login would run against
        // — and be written back to — the wrong server. Pass the active profile's real
        // management URL so login targets the user's own server and the config keeps it.
        let activeProfileID = ProfileManager.shared.getActiveProfileID()
        // managementURL(forID:) already recovers the URL from the config file and
        // then the connection cache. A nil result therefore means no server URL
        // is persisted anywhere — which only
        // happens on a genuine first-time login, where falling back to the default
        // cloud server is correct. For a re-login the config file exists and its URL
        // is preserved even when "" is passed (SDK's apply() only overrides the
        // config URL when a non-empty one is provided). Log the nil case so a rare
        // corrupted state (own-server profile that lost every URL source, which would
        // silently fall back to the default cloud) is visible in diagnostics.
        let resolvedURL = ProfileManager.shared.managementURL(forID: activeProfileID)
        if resolvedURL == nil {
            logger.warning("performLogin: no persisted management URL for '\(activeProfileID, privacy: .public)' — login will use the default cloud server")
        }
        let activeManagementURL = resolvedURL ?? ""
        logger.info("performLogin: using management URL '\(activeManagementURL, privacy: .public)' for profile '\(activeProfileID, privacy: .public)'")
        // The account this login targets is decided by the Go SDK: it reads the
        // profile's stored account and sends it as the OIDC login_hint, and the
        // management server's login flag decides whether the IdP is asked to
        // re-authenticate. Nothing here rewrites the authorize URL.
        if let configPath = Preferences.configFile(), !configPath.isEmpty,
           let auth = NetBirdSDKNewAuth(configPath, activeManagementURL, nil) {
            // A stale flow from an abandoned attempt would keep its loopback port
            // bound and its WaitToken goroutine alive — stop it first.
            self.pendingAuth?.stop()
            self.pendingAuth = auth
            self.loginAttemptToken += 1
            self.loginSucceeded = false
            let urlOpener = MainAppLoginURLOpener()
            let errListener = MainAppLoginErrListener()
            // Set once the browser actually opened. Gates the ownership-conflict
            // self-heal below: an error before the browser phase falls through to the
            // IPC fallback, and retrying concurrently with it would race two flows.
            var browserPhaseStarted = false

            let receivedURL: String? = await withCheckedContinuation { continuation in
                var resumed = false
                let resume: (String?) -> Void = { url in
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(returning: url)
                }
                urlOpener.onOpen = { [weak self] url, _ in
                    // Set showBrowser and resume the continuation in the SAME main-queue
                    // block. onOpen is invoked from a background goroutine, so resuming
                    // before showBrowser is committed lets loginIfRequired() observe
                    // showBrowser == false and spuriously start the VPN — which launches
                    // the extension, trips its needsLogin path, and pops the auth alert
                    // in parallel with this browser login. Ordering them guarantees the
                    // await caller sees showBrowser == true.
                    let browserURL = url
                    DispatchQueue.main.async {
                        browserPhaseStarted = true
                        self?.loginErrorMessage = nil
                        self?.pendingAuthorizeURL = browserURL
                        self?.loginURL = browserURL
                        self?.showBrowser = true
                        resume(url)
                    }
                }
                urlOpener.onSuccess = { [weak self] in
                    var err: NSError?
                    let json = auth.getConfigJSON(&err)
                    if err == nil, !json.isEmpty {
                        _ = Preferences.saveConfigToUserDefaults(json)
                        if let path = Preferences.configFile() {
                            try? json.write(toFile: path, atomically: true, encoding: .utf8)
                        }
                    }
                    // Record the management URL in the connection cache and the shared
                    // UserDefaults so the user's own server is available to the next login
                    // even before the config file can be read back.
                    if !activeManagementURL.isEmpty {
                        ProfileManager.shared.saveServerURL(activeManagementURL, forID: activeProfileID)
                        Preferences.saveManagementURL(activeManagementURL)
                    }
                    // The account this login ran under is recorded by the SDK itself,
                    // keyed by the config path it was handed, so the next login for
                    // this profile goes out with it as the login_hint.
                    AppLogger.shared.log("performLogin: SDK login succeeded for '\(activeProfileID)'")
                    // onSuccess runs on a background goroutine. Mark success on the main
                    // queue so the browser-finished handler (also main-queue) reliably
                    // observes it.
                    DispatchQueue.main.async {
                        guard let self else { return }
                        // Success is delivered twice (urlOpener.onLoginSuccess and the
                        // result listener); act on the first only.
                        guard !self.loginSucceeded else { return }
                        self.logger.info("performLogin: SDK login succeeded")
                        self.loginSucceeded = true
                        self.pendingAuth = nil
                        self.pendingAuthorizeURL = nil
                        // If the browser is already gone, the view's completion handler
                        // deferred the decision to us — the login only finished now, so
                        // start the VPN here. While it is still open, the view starts it
                        // when the user dismisses the success page.
                        if !self.showBrowser {
                            self.logger.info("performLogin: login completed after browser closed - starting VPN")
                            // The management login just completed here, so the extension
                            // can skip its own needs-login check (one Login RPC).
                            self.startVPNConnection(loginVerified: true)
                        }
                    }
                }
                errListener.onSuccessCallback = { urlOpener.onSuccess?() }
                errListener.onErrorCallback = { [weak self] error in
                    // Surface the reason: a login that dies after the browser phase
                    // (failed token exchange or management registration) is otherwise
                    // indistinguishable from "nothing happened".
                    let message = error?.localizedDescription ?? "unknown login error"
                    AppLogger.shared.log("performLogin: SDK login failed: \(message)")
                    // onError runs on a background goroutine; mutate state on the main
                    // queue to stay consistent with onSuccess and cancelLogin().
                    DispatchQueue.main.async {
                        // Resume on the main queue, like onOpen does. `resumed` is a plain
                        // captured var: resuming from the callback's own goroutine thread
                        // while onOpen's queued block is still pending races it, and two
                        // resumes of a checked continuation trap rather than fail softly.
                        // Deferred so every exit path below still resumes.
                        defer { resume(nil) }
                        guard let self else { return }
                        self.logger.error("performLogin: SDK login failed: \(message, privacy: .public)")
                        self.pendingAuth = nil
                        self.pendingAuthorizeURL = nil
                        guard browserPhaseStarted else { return }
                        // "peer is already registered by a different User or a Setup
                        // Key" means the account that signed in does not own this
                        // profile's peer. Report it rather than "repairing" it: the
                        // app cannot tell a stale local key from a login under the
                        // wrong account, and deleting the profile's identity to fix
                        // the latter destroys a working registration and can
                        // re-register the peer under the wrong account. Removing an
                        // identity stays an explicit user action — Profiles → Log out.
                        if message.contains("registered by a different User") {
                            self.loginErrorMessage = """
                                This profile belongs to a different NetBird account. \
                                Sign in with the account that owns it, or log the \
                                profile out (Profiles → Log out) to register it again.
                                """
                        } else {
                            self.loginErrorMessage = message
                        }
                        self.showBrowser = false
                    }
                }
                // Pass the device name explicitly. The plain login() path uses an empty
                // device name, which makes the management server register the peer under
                // the machine hostname fallback instead of the user's device name
                // (UIDevice.current.name). This only affects first-time registration —
                // a re-login reuses the persisted config/identity — but that first peer
                // would otherwise show up as "hostname".
                // loginInteractive skips the SDK's own IsLoginRequired() pre-flight: we only
                // reach performLogin() after loginIfRequired() established that login is
                // needed, and that pre-flight is itself a full Login RPC.
                auth.loginInteractive(errListener, urlOpener: urlOpener, forceDeviceAuth: false, deviceName: Device.getName())
            }

            if let url = receivedURL, !url.isEmpty {
                logger.info("performLogin: auth started in main-app process")
                return
            }
            logger.error("performLogin: main-app auth failed to get URL, falling back to IPC")
            self.pendingAuth = nil
        }
        #endif

        #if os(tvOS)
        let retryState = loginRetryState
        let retryGeneration = retryState.begin()

        // On tvOS the device-auth flow runs inside the extension (via the "LoginTV"
        // IPC), and IPC only reaches a RUNNING extension. Boot the tunnel first: when
        // login is required, the extension parks its startTunnel instead of failing,
        // keeping the process alive for the whole auth flow.
        if self.vpnManager?.connection.status == .disconnected
            || self.vpnManager?.connection.status == .invalid {
            logger.info("performLogin: tvOS - starting tunnel to boot extension for device auth")
            startVPNConnection()
        }

        let loginURLString: String? = await withCheckedContinuation { continuation in
            var attempts = 0
            let maxAttempts = 12

            func attempt() {
                guard retryState.isActive(retryGeneration) else {
                    continuation.resume(returning: nil)
                    return
                }

                attempts += 1
                // Push the server config each round: early attempts may run before the
                // extension process is up, and the extension needs the management URL
                // (custom servers) before it can start the device-auth flow.
                if attempts > 1, let configJSON = Preferences.loadConfigFromUserDefaults(), !configJSON.isEmpty {
                    self.sendConfigToExtension(configJSON)
                    if let url = Preferences.loadManagementURL() {
                        let messageString = "SetManagementURL:\(url)"
                        if let data = messageString.data(using: .utf8) {
                            try? self.session?.sendProviderMessage(data) { _ in }
                        }
                    }
                }

                self.login { urlString in
                    guard retryState.isActive(retryGeneration) else {
                        continuation.resume(returning: nil)
                        return
                    }

                    if let urlString = urlString, !urlString.isEmpty {
                        continuation.resume(returning: urlString)
                    } else if attempts < maxAttempts {
                        DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) {
                            attempt()
                        }
                    } else {
                        continuation.resume(returning: nil)
                    }
                }
            }

            attempt()
        }
        #else
        // Fallback: IPC to the NE extension (if main-app auth setup failed)
        let loginURLString: String? = await withCheckedContinuation { continuation in
            self.login { urlString in
                continuation.resume(returning: urlString)
            }
        }
        #endif
        #if os(tvOS)
        guard retryState.isActive(retryGeneration) else {
            logger.info("performLogin: tvOS login IPC retry loop cancelled")
            return
        }
        #endif
        guard let url = loginURLString, !url.isEmpty else {
            logger.error("performLogin: no login URL received from extension, aborting")
            return
        }
        // performLogin() is a nonisolated async method, so its body runs on the
        // cooperative pool even when start() called it from the main actor — a
        // nonisolated function does not inherit the caller's actor. loginURL and
        // showBrowser are @Published, and publishing off the main thread is
        // undefined behaviour in SwiftUI. Same ordering as the main-app path above:
        // showBrowser is committed together with the URL it belongs to.
        await MainActor.run {
            self.loginURL = url
            self.showBrowser = true
        }
    }


    #if os(iOS)
    /// Aborts an in-progress interactive login (e.g. the user dismissed the OAuth
    /// browser without completing it). Stopping the SDK auth cancels its context,
    /// which unblocks the PKCE WaitToken and shuts down the loopback HTTP server so
    /// the redirect port is freed immediately. Without this the next connect stalls
    /// trying to bind the same port until the previous flow expires.
    public func cancelLogin() {
        logger.info("cancelLogin: aborting in-progress login")
        pendingAuth?.stop()
        pendingAuth = nil
        pendingAuthorizeURL = nil
        loginSucceeded = false
        showBrowser = false
    }

    /// Decides what a dismissed login browser means and calls `abort` only when the
    /// login is definitely not in flight.
    ///
    /// The system auth session reports the same "cancelled" completion whether the
    /// user backed out of the IdP page or closed the SDK's success page after the
    /// redirect already went through, so the dismissal alone cannot be trusted. The
    /// SDK's loopback listener settles it: it stays bound while the flow is still
    /// waiting for the authorization code and goes away once the code arrives. A
    /// listener that is still up on two probes means nothing was delivered — a real
    /// cancel. Anything else defers to the SDK, with a bounded fallback so a login
    /// that dies silently cannot leave the UI stuck on "Connecting…".
    public func resolveLoginAfterBrowserClose(abort: @escaping () -> Void) {
        let token = loginAttemptToken
        // `abort` must never fire for an attempt other than the one being resolved.
        let abortIfStillCurrent: () -> Void = { [weak self] in
            guard let self, self.loginAttemptToken == token,
                  !self.loginSucceeded, !self.showBrowser else { return }
            abort()
        }

        guard let endpoint = pendingAuthorizeURL.flatMap(Self.loopbackEndpoint(fromAuthorizeURL:)) else {
            logger.info("resolveLoginAfterBrowserClose: no loopback endpoint known, deferring to SDK result")
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.loginResolutionTimeout, execute: abortIfStillCurrent)
            return
        }

        Self.probeListener(host: endpoint.host, port: endpoint.port) { [weak self] listening in
            guard let self else { return }
            guard listening else {
                self.logger.info("resolveLoginAfterBrowserClose: loopback listener gone — code delivered, waiting for the SDK")
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.loginResolutionTimeout, execute: abortIfStillCurrent)
                return
            }
            // Still listening: either nothing was delivered, or the code arrived and
            // the token exchange is running with the listener briefly still up.
            // Re-probe once before treating it as a cancel so a live exchange is
            // never killed.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.loopbackRecheckDelay) {
                Self.probeListener(host: endpoint.host, port: endpoint.port) { stillListening in
                    DispatchQueue.main.async {
                        if stillListening {
                            self.logger.info("resolveLoginAfterBrowserClose: loopback still waiting for the code — treating as cancelled")
                            abortIfStillCurrent()
                        } else {
                            self.logger.info("resolveLoginAfterBrowserClose: code delivered late, waiting for the SDK")
                            DispatchQueue.main.asyncAfter(deadline: .now() + Self.loginResolutionTimeout, execute: abortIfStillCurrent)
                        }
                    }
                }
            }
        }
    }

    /// How long to wait for the SDK's verdict once the code is known to be delivered.
    /// Covers a first-time peer registration, which can outlast the browser session.
    private static let loginResolutionTimeout: TimeInterval = 20
    /// Gap between loopback probes, long enough to cover a token exchange.
    private static let loopbackRecheckDelay: TimeInterval = 3

    /// Extracts the loopback host/port the SDK told the IdP to redirect to.
    static func loopbackEndpoint(fromAuthorizeURL urlString: String) -> (host: String, port: UInt16)? {
        guard let components = URLComponents(string: urlString),
              let redirect = components.queryItems?.first(where: { $0.name == "redirect_uri" })?.value,
              let redirectComponents = URLComponents(string: redirect),
              let host = redirectComponents.host,
              let port = redirectComponents.port,
              let port16 = UInt16(exactly: port)
        else { return nil }
        return (host, port16)
    }

    /// Reports whether something accepts TCP connections at host:port.
    private static func probeListener(host: String, port: UInt16, completion: @escaping (Bool) -> Void) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            completion(false)
            return
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        // Both the connection's state updates and the timeout below run here. A
        // serial queue is what makes `settled` safe: on a concurrent queue the
        // watchdog could run alongside a state update, and the check-then-set would
        // let both through — cancelling twice and reporting the result twice.
        let queue = DispatchQueue(label: "io.netbird.loopback-probe")
        var settled = false
        let settle: (Bool) -> Void = { listening in
            guard !settled else { return }
            settled = true
            connection.cancel()
            completion(listening)
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                settle(true)
            case .failed, .cancelled:
                settle(false)
            case .waiting:
                // Connection refused surfaces as .waiting with a retry — for loopback
                // that means nothing is bound.
                settle(false)
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 2) { settle(false) }
    }
    #endif

    /// Starts the tunnel.
    /// - Parameter loginVerified: pass true only when this process has just established the
    ///   login state — either its own isLoginRequired() check returned false, or an
    ///   interactive login completed successfully. The extension then skips its own
    ///   needs-login check, which is a full Login RPC against the management server.
    ///   Defaults to false so any caller that has not verified stays on the safe path.
    public func startVPNConnection(loginVerified: Bool = false) {
        logger.info("startVPNConnection: called (loginVerified=\(loginVerified))")
        let logLevel = UserDefaults.standard.string(forKey: "logLevel") ?? "INFO"
        logger.info("startVPNConnection: logLevel = \(logLevel)")
        var options: [String: NSObject] = ["logLevel": logLevel as NSObject]
        #if os(iOS)
        if loginVerified {
            options[GlobalConstants.optionLoginVerified] = true as NSObject
        }
        // Pass active profile paths so the extension can reinitialize the adapter
        // if the profile changed while the extension process was still alive.
        let configPath = Preferences.configFile()
        let statePath  = Preferences.stateFile()
        if let configPath {
            options["configPath"] = configPath as NSObject
        }
        if let statePath {
            options["statePath"] = statePath as NSObject
        }
        logger.info("startVPNConnection: configPath=\(configPath ?? "nil")")

        // Persist the active paths to the shared app group so the widget intent
        // can pass them to startVPNTunnel(options:) when the main app is not running.
        let sharedDefaults = UserDefaults(suiteName: GlobalConstants.userPreferencesSuiteName)
        sharedDefaults?.set(configPath, forKey: GlobalConstants.keyWidgetActiveConfigPath)
        sharedDefaults?.set(statePath,  forKey: GlobalConstants.keyWidgetActiveStatePath)
        #endif

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
        #if os(tvOS)
        loginRetryState.cancel()
        #endif
        self.vpnManager?.connection.stopVPNTunnel()
    }

    /// Outcome of an On Demand update. Callers that persist or display the state must wait
    /// for this before claiming the change took effect.
    enum OnDemandUpdate {
        /// The rules were written to the tunnel manager.
        case applied
        /// There was nothing to arm — no manager exists yet, or no configuration to connect
        /// with. The stored preference stands and `applyExtensionStatus` arms it after the
        /// next successful connection.
        case deferred
        /// The tunnel manager rejected the change; what is in force is still the old state.
        case failed(Error?)
    }

    /// Last requested On Demand state, kept because the manager may still be loading when
    /// the next request arrives. Locked like `isFetchingStatus`: requests come from the main
    /// queue and from the (non-isolated) async login path.
    private let onDemandLock = NSLock()
    private var _requestedOnDemandState: Bool?
    private var requestedOnDemandState: Bool? {
        get { onDemandLock.lock(); defer { onDemandLock.unlock() }; return _requestedOnDemandState }
        set { onDemandLock.lock(); defer { onDemandLock.unlock() }; _requestedOnDemandState = newValue }
    }

    /// Updates the VPN On Demand configuration on the current manager.
    /// When enabled, iOS will automatically reconnect the VPN after network changes or reboot.
    /// Should only be enabled when the user is logged in to avoid reconnect loops.
    func setOnDemandEnabled(_ enabled: Bool, completion: ((OnDemandUpdate) -> Void)? = nil) {
        if enabled && !hasUsableConfigForOnDemand() {
            logger.warning("setOnDemandEnabled: Refusing to enable On Demand — user is not logged in")
            completion?(.deferred)
            return
        }

        // Record the request before any async work: a state that arrives while the manager
        // is still loading must win over the one that started that load, or the stale value
        // gets written after it.
        requestedOnDemandState = enabled

        guard let manager = self.vpnManager else {
            // Nothing is armed without a manager, so disabling is already the effective
            // state. Never configure one just to switch On Demand off — that would create
            // the VPN configuration (and its system prompt) from a background code path.
            guard enabled else {
                logger.info("setOnDemandEnabled: No VPN manager — nothing is armed, disable is already in force")
                completion?(.deferred)
                return
            }

            // The manager is created lazily on the first connect. On tvOS the On Demand
            // toggle lives in Settings and can be flipped before that ever happens, so
            // load (or create) the manager here instead of dropping the change.
            logger.info("setOnDemandEnabled: No VPN manager yet — configuring one first")
            Task { @MainActor in
                do {
                    try await self.configureManager()
                } catch {
                    self.logger.error("setOnDemandEnabled: configureManager failed: \(error.localizedDescription)")
                    completion?(.failed(error))
                    return
                }
                guard let manager = self.vpnManager else {
                    self.logger.error("setOnDemandEnabled: manager still unavailable after configureManager")
                    completion?(.failed(nil))
                    return
                }
                // Apply the latest request rather than the one this task was started for.
                let state = self.requestedOnDemandState ?? enabled
                if state != enabled {
                    self.logger.info("setOnDemandEnabled: superseded while configuring, applying \(state) instead of \(enabled)")
                }
                self.applyOnDemandState(state, to: manager, completion: completion)
            }
            return
        }

        applyOnDemandState(enabled, to: manager, completion: completion)
    }

    /// Writes the On Demand state and matching rules to the given manager.
    ///
    /// A request that matches what the manager already holds is answered without a write:
    /// saveToPreferences on a configured manager makes NE emit NEVPNStatusDidChange — a
    /// transient .disconnecting among them — and rewriting the rules of a live tunnel can
    /// have the system reassert it. applyExtensionStatus arms On Demand on every transition
    /// to .connected, so an unconditional write added a spurious disconnect to every connect.
    private func applyOnDemandState(_ enabled: Bool, to manager: NETunnelProviderManager, completion: ((OnDemandUpdate) -> Void)? = nil) {
        let rules = enabled ? onDemandRulesForStoredSettings() : []

        if manager.isOnDemandEnabled == enabled,
           onDemandRulesMatch(manager.onDemandRules ?? [], rules) {
            logger.info("setOnDemandEnabled: already \(enabled ? "enabled" : "disabled") with the same rules, skipping write")
            completion?(.applied)
            return
        }

        manager.onDemandRules = rules
        manager.isOnDemandEnabled = enabled

        manager.saveToPreferences { error in
            if let error = error {
                self.logger.error("setOnDemandEnabled: Failed to save preferences: \(error.localizedDescription)")
                completion?(.failed(error))
            } else {
                self.logger.info("setOnDemandEnabled: On Demand \(enabled ? "enabled" : "disabled") successfully")
                completion?(.applied)
            }
        }
    }

    /// Rules to arm On Demand with, built from the persisted policies. An explicit Ignore
    /// rule stands in for "all policies are Do Nothing" so the system does not interfere
    /// with the connection state.
    private func onDemandRulesForStoredSettings() -> [NEOnDemandRule] {
        let rules = buildOnDemandRules()
        guard rules.isEmpty else { return rules }

        let ignoreRule = NEOnDemandRuleIgnore()
        ignoreRule.interfaceTypeMatch = .any
        return [ignoreRule]
    }

    /// Compares two rule sets by their archived form. NEOnDemandRule has no value-based
    /// isEqual, so comparing the objects would report every freshly built set as different
    /// and defeat the skip above. An archive that cannot be produced counts as "different",
    /// which falls back to writing — the old, always-write behaviour.
    private func onDemandRulesMatch(_ lhs: [NEOnDemandRule], _ rhs: [NEOnDemandRule]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        guard let lhsData = archivedOnDemandRules(lhs),
              let rhsData = archivedOnDemandRules(rhs) else { return false }
        return lhsData == rhsData
    }

    private func archivedOnDemandRules(_ rules: [NEOnDemandRule]) -> Data? {
        do {
            return try NSKeyedArchiver.archivedData(withRootObject: rules, requiringSecureCoding: true)
        } catch {
            logger.debug("archivedOnDemandRules: could not archive rules: \(error.localizedDescription)")
            return nil
        }
    }

    /// True when there is a configuration the extension can connect with unattended.
    /// On Demand must not be armed before that — the system would otherwise keep
    /// starting a tunnel that immediately fails with "login required".
    private func hasUsableConfigForOnDemand() -> Bool {
        #if os(tvOS)
        // tvOS never writes keyLoginRequired: the app-group defaults are not shared with
        // the extension there, so the login state is tracked through the stored config.
        return Preferences.hasConfigInUserDefaults()
        #else
        let defaults = UserDefaults(suiteName: GlobalConstants.userPreferencesSuiteName)
        return !(defaults?.bool(forKey: GlobalConstants.keyLoginRequired) ?? true)
        #endif
    }

    /// Applies granular On Demand rules based on Wi-Fi/Cellular policies and network lists.
    func applyOnDemandRules(wifiPolicy: WiFiOnDemandPolicy, cellularPolicy: CellularOnDemandPolicy, wifiNetworks: [String]) {
        guard let manager = self.vpnManager else {
            logger.warning("applyOnDemandRules: No VPN manager available")
            return
        }

        let rules = buildOnDemandRulesFrom(wifiPolicy: wifiPolicy, cellularPolicy: cellularPolicy, wifiNetworks: wifiNetworks)
        if rules.isEmpty {
            // All policies are "Do Nothing" — don't interfere with connection state
            let ignoreRule = NEOnDemandRuleIgnore()
            ignoreRule.interfaceTypeMatch = .any
            manager.onDemandRules = [ignoreRule]
        } else {
            manager.onDemandRules = rules
        }

        manager.saveToPreferences { error in
            if let error = error {
                self.logger.error("applyOnDemandRules: Failed to save preferences: \(error.localizedDescription)")
            } else {
                self.logger.info("applyOnDemandRules: Rules applied successfully")
            }
        }
    }

    /// Builds NEOnDemandRule array from persisted UserDefaults settings.
    private func buildOnDemandRules() -> [NEOnDemandRule] {
        let userDefaults = UserDefaults(suiteName: GlobalConstants.userPreferencesSuiteName)
        let wifiRaw = userDefaults?.string(forKey: GlobalConstants.keyOnDemandWiFiPolicy) ?? WiFiOnDemandPolicy.always.rawValue
        let cellularRaw = userDefaults?.string(forKey: GlobalConstants.keyOnDemandCellularPolicy) ?? CellularOnDemandPolicy.always.rawValue
        let wifiPolicy = WiFiOnDemandPolicy(rawValue: wifiRaw) ?? .always
        let cellularPolicy = CellularOnDemandPolicy(rawValue: cellularRaw) ?? .always
        let wifiNetworks = userDefaults?.stringArray(forKey: GlobalConstants.keyOnDemandWiFiNetworks) ?? []
        return buildOnDemandRulesFrom(wifiPolicy: wifiPolicy, cellularPolicy: cellularPolicy, wifiNetworks: wifiNetworks)
    }

    /// Converts policy enums into NEOnDemandRule objects.
    private func buildOnDemandRulesFrom(wifiPolicy: WiFiOnDemandPolicy, cellularPolicy: CellularOnDemandPolicy, wifiNetworks: [String]) -> [NEOnDemandRule] {
        #if os(tvOS)
        // Apple TV exposes a single "always connect" behaviour: there are no per-network
        // rules (NEHotspotNetwork is unavailable) and no cellular interface. The match must
        // be .any rather than .wiFi — an Apple TV on Ethernet never matches a Wi-Fi rule,
        // and wired setups are exactly the always-on ones this is meant to serve.
        let rule = NEOnDemandRuleConnect()
        rule.interfaceTypeMatch = .any
        return [rule]
        #else
        var rules: [NEOnDemandRule] = []

        // Wi-Fi rules
        switch wifiPolicy {
        case .always:
            let rule = NEOnDemandRuleConnect()
            rule.interfaceTypeMatch = .wiFi
            rules.append(rule)
        case .onlyOn:
            if !wifiNetworks.isEmpty {
                let connectRule = NEOnDemandRuleConnect()
                connectRule.interfaceTypeMatch = .wiFi
                connectRule.ssidMatch = wifiNetworks
                rules.append(connectRule)
            }
            // Disconnect on all other Wi-Fi networks (or all Wi-Fi if list is empty)
            let disconnectRule = NEOnDemandRuleDisconnect()
            disconnectRule.interfaceTypeMatch = .wiFi
            rules.append(disconnectRule)
        case .exceptOn:
            if !wifiNetworks.isEmpty {
                let disconnectRule = NEOnDemandRuleDisconnect()
                disconnectRule.interfaceTypeMatch = .wiFi
                disconnectRule.ssidMatch = wifiNetworks
                rules.append(disconnectRule)
            }
            let connectRule = NEOnDemandRuleConnect()
            connectRule.interfaceTypeMatch = .wiFi
            rules.append(connectRule)
        case .never:
            let rule = NEOnDemandRuleDisconnect()
            rule.interfaceTypeMatch = .wiFi
            rules.append(rule)
        case .doNothing:
            break
        }

        // Cellular rules
        switch cellularPolicy {
        case .always:
            let rule = NEOnDemandRuleConnect()
            rule.interfaceTypeMatch = .cellular
            rules.append(rule)
        case .never:
            let rule = NEOnDemandRuleDisconnect()
            rule.interfaceTypeMatch = .cellular
            rules.append(rule)
        case .doNothing:
            break
        }

        return rules
        #endif
    }

    /// Returns the current On Demand enabled state from the VPN manager.
    var isOnDemandEnabled: Bool {
        return vpnManager?.isOnDemandEnabled ?? false
    }

    func login(completion: @escaping (String?) -> Void) {
        guard let session = self.session else {
            logger.error("login: No session available for login")
            completion(nil)
            return
        }

        do {
            // Use LoginTV for tvOS to force device auth flow
            #if os(tvOS)
            let messageString = "LoginTV"
            #else
            // Include active profile paths so the extension can reinitialize
            // its adapter for the correct profile before performing login.
            // Also include the management URL — resolved from the profile config,
            // falling back to the connection cache — so the extension can restore
            // a missing config (e.g. after logout) and use the correct server.
            // Format: "Login:<configPath>|<statePath>[|<managementURL>]"
            var messageString = "Login"
            if let configPath = Preferences.configFile(), let statePath = Preferences.stateFile() {
                messageString = "Login:\(configPath)|\(statePath)"
                let activeID = ProfileManager.shared.getActiveProfileID()
                if let managementURL = ProfileManager.shared.managementURL(forID: activeID),
                   !managementURL.isEmpty {
                    messageString += "|\(managementURL)"
                }
            }
            #endif

            if let messageData = messageString.data(using: .utf8) {
                // Send the message to the network extension
                try session.sendProviderMessage(messageData) { response in
                    guard let response = response else {
                        self.logger.error("login: No response from extension")
                        completion(nil)
                        return
                    }
                    #if os(tvOS)
                    // For tvOS, decode DeviceAuthResponse struct
                    do {
                        let authResponse = try self.decoder.decode(DeviceAuthResponse.self, from: response)
                        DispatchQueue.main.async {
                            self.userCode = authResponse.userCode
                        }
                        completion(authResponse.url)
                    } catch {
                        print("login: Failed to decode DeviceAuthResponse - \(error)")
                        // Fallback to plain string for backwards compatibility
                        completion(String(data: response, encoding: .utf8))
                    }
                    #else
                    completion(String(data: response, encoding: .utf8))
                    #endif
                }
            } else {
                print("Error converting message to Data")
                completion(nil)
            }
        } catch {
            print("error when performing network extension action")
            completion(nil)
        }
    }

    /// Fetch login diagnostics from the Network Extension in a single IPC round-trip.
    /// This queries the same SDK client that is actually performing the login.
    /// Callers derive both error and completion state from the same response.
    func checkLoginDiagnostics(completion: @escaping (LoginDiagnostics?) -> Void) {
        guard let session = self.session else {
            logger.error("checkLoginDiagnostics: No session available")
            completion(nil)
            return
        }

        let messageString = "IsLoginComplete"
        guard let messageData = messageString.data(using: .utf8) else {
            print("checkLoginDiagnostics: Failed to encode message")
            completion(nil)
            return
        }

        do {
            try session.sendProviderMessage(messageData) { response in
                if let response = response {
                    do {
                        let diagnostic = try self.decoder.decode(LoginDiagnostics.self, from: response)
                        print("checkLoginDiagnostics: result=\(diagnostic.isComplete), isExecuting=\(diagnostic.isExecuting), loginRequired=\(diagnostic.loginRequired), configExists=\(diagnostic.configExists), stateExists=\(diagnostic.stateExists), lastResult=\(diagnostic.lastResult), lastError=\(diagnostic.lastError)")
                        completion(diagnostic)
                    } catch {
                        print("checkLoginDiagnostics: Failed to decode LoginDiagnostics - \(error)")
                        completion(nil)
                    }
                } else {
                    print("checkLoginDiagnostics: No response from extension")
                    completion(nil)
                }
            }
        } catch {
            print("checkLoginDiagnostics: Failed to send message - \(error)")
            completion(nil)
        }
    }

    /// Persists configuration returned by a completed tvOS device-auth flow.
    /// Kept separate from checkLoginDiagnostics so polling remains a read-only operation.
    func persistLoginConfiguration(from diagnostic: LoginDiagnostics) {
        #if os(tvOS)
        guard diagnostic.isComplete,
              let configJSON = diagnostic.configJSON,
              !configJSON.isEmpty else {
            return
        }

        if Preferences.saveConfigToUserDefaults(configJSON) {
            logger.info("persistLoginConfiguration: saved post-login config in main app")
        } else {
            logger.error("persistLoginConfiguration: failed to save post-login config in main app")
        }
        #endif
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
        // Callers (e.g. RoutesViewModel.selectRoute) balance a DispatchGroup enter/leave
        // around this call, so completion must fire on every exit path or the group hangs
        // and the pending select is never sent.
        let routes = RoutesSelectionDetails(all: false, append: false, routeSelectionInfo: [])

        guard let session = self.session else {
            completion(routes)
            return
        }

        let messageString = "Deselect-\(id)"
        if let messageData = messageString.data(using: .utf8) {
            do {
                try session.sendProviderMessage(messageData) { response in
                    completion(routes)
                }
            } catch {
                print("Failed to send Provider message")
                completion(routes)
            }
        } else {
            print("Error converting message to Data")
            completion(routes)
        }
    }
    
    func uploadDebugBundle(anonymize: Bool, completion: @escaping (Result<String, Error>) -> Void) {
        guard let session = self.session else {
            completion(.failure(NSError(domain: "NetBird", code: -1, userInfo: [NSLocalizedDescriptionKey: "VPN session not available. Connect first."])))
            return
        }
        let message = "DebugBundle:\(anonymize ? "true" : "false")"
        guard let messageData = message.data(using: .utf8) else {
            completion(.failure(NSError(domain: "NetBird", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to encode message"])))
            return
        }
        do {
            try session.sendProviderMessage(messageData) { response in
                guard let data = response, let text = String(data: data, encoding: .utf8) else {
                    completion(.failure(NSError(domain: "NetBird", code: -3, userInfo: [NSLocalizedDescriptionKey: "No response from extension"])))
                    return
                }
                if text.hasPrefix("error:") {
                    let msg = String(text.dropFirst("error:".count))
                    completion(.failure(NSError(domain: "NetBird", code: -4, userInfo: [NSLocalizedDescriptionKey: msg])))
                } else {
                    completion(.success(text))
                }
            }
        } catch {
            completion(.failure(error))
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

    #if os(tvOS)
    /// Send config JSON to the Network Extension via IPC
    /// On tvOS, shared UserDefaults doesn't work between app and extension,
    /// so we transfer config directly via IPC
    func sendConfigToExtension(_ configJSON: String, completion: ((Bool) -> Void)? = nil) {
        guard let session = self.session else {
            logger.warning("sendConfigToExtension: No session available")
            completion?(false)
            return
        }

        let messageString = "SetConfig:\(configJSON)"
        guard let messageData = messageString.data(using: .utf8) else {
            logger.error("sendConfigToExtension: Failed to convert message to Data")
            completion?(false)
            return
        }

        do {
            try session.sendProviderMessage(messageData) { response in
                if let response = response,
                   let responseString = String(data: response, encoding: .utf8),
                   responseString == "true" {
                    self.logger.info("sendConfigToExtension: Config sent successfully")
                    completion?(true)
                } else {
                    self.logger.warning("sendConfigToExtension: Extension did not confirm receipt")
                    completion?(false)
                }
            }
        } catch {
            logger.error("sendConfigToExtension: Failed to send message: \(error.localizedDescription)")
            completion?(false)
        }
    }

    /// Clear extension-local config on logout
    /// This ensures the extension doesn't have stale credentials after logout
    func clearExtensionConfig(completion: ((Bool) -> Void)? = nil) {
        guard let session = self.session else {
            logger.warning("clearExtensionConfig: No session available")
            completion?(false)
            return
        }

        let messageString = "ClearConfig"
        guard let messageData = messageString.data(using: .utf8) else {
            logger.error("clearExtensionConfig: Failed to convert message to Data")
            completion?(false)
            return
        }

        do {
            try session.sendProviderMessage(messageData) { response in
                if let response = response,
                   let responseString = String(data: response, encoding: .utf8),
                   responseString == "true" {
                    self.logger.info("clearExtensionConfig: Extension config cleared successfully")
                    completion?(true)
                } else {
                    self.logger.warning("clearExtensionConfig: Extension did not confirm clearing")
                    completion?(false)
                }
            }
        } catch {
            logger.error("clearExtensionConfig: Failed to send message: \(error.localizedDescription)")
            completion?(false)
        }
    }
    #endif

    func getExtensionStatus(completion: @escaping (NEVPNStatus) -> Void) {
        Task {
            do {
                let managers = try await NETunnelProviderManager.loadAllFromPreferences()
                if let manager = managers.first(where: { $0.localizedDescription == self.extensionName }) {
                    completion(manager.connection.status)
                } else {
                    // No VPN manager exists yet (e.g. first connect before the iOS permission
                    // dialog completes). Must still call completion so that isCheckingExtensionState
                    // is reset to false; otherwise checkExtensionState() is permanently blocked.
                    completion(.disconnected)
                }
            } catch {
                print("Error loading from preferences: \(error)")
                completion(.disconnected)
            }
        }
    }
}
