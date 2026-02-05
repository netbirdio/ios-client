//
//  NetBirdAdapter.swift
//  NetBirdiOS
//
//  Created by Pascal Fischer on 08.08.23.
//

import Foundation
import NetworkExtension
import NetBirdSDK
import os

/// Logger for NetBirdAdapter - visible in Console.app
private let adapterLogger = Logger(subsystem: "io.netbird.adapter", category: "NetBirdAdapter")

// URL Opener for Login Flow
class LoginURLOpener: NSObject, NetBirdSDKURLOpenerProtocol {
    var onOpen: ((String, String) -> Void)?
    var onSuccess: (() -> Void)?

    func open(_ url: String?, userCode: String?) {
        guard let url = url else { return }
        onOpen?(url, userCode ?? "")
    }

    func onLoginSuccess() {
        onSuccess?()
    }
}

// Error Listener for Async Operations
class LoginErrListener: NSObject, NetBirdSDKErrListenerProtocol {
    var onErrorCallback: ((Error?) -> Void)?
    var onSuccessCallback: (() -> Void)?

    func onError(_ err: Error?) {
        onErrorCallback?(err)
    }

    func onSuccess() {
        onSuccessCallback?()
    }
}

// SSO Listener for Config Save
class LoginConfigSaveListener: NSObject, NetBirdSDKSSOListenerProtocol {
    var onResult: ((Bool?, Error?) -> Void)?

    func onSuccess(_ ssoSupported: Bool) {
        onResult?(ssoSupported, nil)
    }

    func onError(_ error: Error?) {
        onResult?(nil, error)
    }
}

public class NetBirdAdapter {

    #if os(tvOS)
    /// Default management URL for tvOS (public NetBird server)
    static let defaultManagementURL = "https://api.netbird.io"
    #endif

    /// Packet tunnel provider.
    private weak var packetTunnelProvider: PacketTunnelProvider?

    private weak var tunnelManager: PacketTunnelProviderSettingsManager?

    public let client : NetBirdSDKClient
    private let networkChangeListener : NetworkChangeListener
    private let dnsManager: DNSManager

    public var isExecutingLogin = false

    /// Tracks the result of the last login attempt for debugging
    public var lastLoginResult: String = "none"
    public var lastLoginError: String = ""

    /// Stores the login URL opener for the duration of the login flow
    private var loginURLOpener: LoginURLOpener?
    /// Stores the error listener for the duration of the login flow
    private var loginErrListener: LoginErrListener?

    private let stateLock = NSLock()
    private var _clientState: ClientState = .disconnected

    var clientState: ClientState {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _clientState }
        set { stateLock.lock(); defer { stateLock.unlock() }; _clientState = newValue }
    }

    private let isRestartingLock = NSLock()
    private var _isRestarting: Bool = false

    /// Flag indicating the client is restarting (e.g., due to network type change).
    /// When true, intermediate state changes (connecting/disconnecting) are suppressed
    /// to prevent UI animation state machine from getting confused.
    var isRestarting: Bool {
        get { isRestartingLock.lock(); defer { isRestartingLock.unlock() }; return _isRestarting }
        set { isRestartingLock.lock(); defer { isRestartingLock.unlock() }; _isRestarting = newValue }
    }

    private let networkUnavailableLock = NSLock()
    private var _isNetworkUnavailable: Bool = false

    /// Flag indicating network is currently unavailable.
    /// When true, onDisconnected() callbacks are suppressed to keep the tunnel alive
    /// and ready to reconnect when network returns.
    var isNetworkUnavailable: Bool {
        get { networkUnavailableLock.lock(); defer { networkUnavailableLock.unlock() }; return _isNetworkUnavailable }
        set { networkUnavailableLock.lock(); defer { networkUnavailableLock.unlock() }; _isNetworkUnavailable = newValue }
    }

    private let stopLock = NSLock()

    /// Tunnel device file descriptor.
    /// On iOS: searches for the utun control socket file descriptor by iterating through
    /// file descriptors and matching against the Apple utun control interface.
    /// On tvOS: uses manually defined structures since the SDK doesn't expose them.
    public var tunnelFileDescriptor: Int32? {
        #if os(iOS)
        var ctlInfo = ctl_info()
        withUnsafeMutablePointer(to: &ctlInfo.ctl_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: $0.pointee)) {
                _ = strcpy($0, "com.apple.net.utun_control")
            }
        }
        for fd: Int32 in 0...1024 {
            var addr = sockaddr_ctl()
            var ret: Int32 = -1
            var len = socklen_t(MemoryLayout.size(ofValue: addr))
            withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    ret = getpeername(fd, $0, &len)
                }
            }
            if ret != 0 || addr.sc_family != AF_SYSTEM {
                continue
            }
            if ctlInfo.ctl_id == 0 {
                ret = ioctl(fd, CTLIOCGINFO, &ctlInfo)
                if ret != 0 {
                    continue
                }
            }
            if addr.sc_id == ctlInfo.ctl_id {
                adapterLogger.info("tunnelFileDescriptor: Found utun FD = \(fd)")
                return fd
            }
        }
        adapterLogger.warning("tunnelFileDescriptor: Could not find utun file descriptor")
        return nil
        #elseif os(tvOS)
        // tvOS SDK doesn't expose ctl_info, sockaddr_ctl, CTLIOCGINFO in headers
        // but the kernel structures exist at runtime. Use raw syscalls.
        return findTunnelFileDescriptorTvOS()
        #else
        return nil
        #endif
    }

    #if os(tvOS)
    /// Find the tunnel file descriptor on tvOS using raw syscalls.
    /// The tvOS SDK doesn't expose ctl_info/sockaddr_ctl in headers, but they exist at runtime.
    private func findTunnelFileDescriptorTvOS() -> Int32? {
        // Constants from sys/kern_control.h (not in tvOS SDK but exist in kernel)
        let AF_SYSTEM: UInt8 = 32
        // Note: AF_SYS_CONTROL, SYSPROTO_CONTROL, UTUN_OPT_IFNAME are documented here
        // but used as literals (2) in getsockopt calls below for clarity
        // CTLIOCGINFO = _IOWR('N', 3, struct ctl_info) = 0xC0644E03
        let CTLIOCGINFO: UInt = 0xC0644E03

        // Structure sizes and offsets based on Darwin kernel headers
        // struct ctl_info { u_int32_t ctl_id; char ctl_name[96]; }
        let ctlInfoSize = 100  // 4 + 96 bytes
        // struct sockaddr_ctl { u_char sc_len; u_char sc_family; u_int16_t ss_sysaddr; u_int32_t sc_id; u_int32_t sc_unit; u_int32_t sc_reserved[5]; }
        let sockaddrCtlSize = 32

        // Allocate ctl_info structure
        let ctlInfo = UnsafeMutableRawPointer.allocate(byteCount: ctlInfoSize, alignment: 4)
        defer { ctlInfo.deallocate() }
        memset(ctlInfo, 0, ctlInfoSize)

        // Set ctl_name to "com.apple.net.utun_control" at offset 4
        let ctlName = "com.apple.net.utun_control"
        _ = ctlName.withCString { cstr in
            memcpy(ctlInfo.advanced(by: 4), cstr, strlen(cstr) + 1)
        }

        // Allocate sockaddr_ctl structure
        let sockaddrCtl = UnsafeMutableRawPointer.allocate(byteCount: sockaddrCtlSize, alignment: 4)
        defer { sockaddrCtl.deallocate() }

        var ctlIdFound: UInt32 = 0

        for fd: Int32 in 0...1024 {
            memset(sockaddrCtl, 0, sockaddrCtlSize)
            var len = socklen_t(sockaddrCtlSize)

            // Call getpeername to get the socket address
            let ret = getpeername(fd, sockaddrCtl.assumingMemoryBound(to: sockaddr.self), &len)
            if ret != 0 {
                continue
            }

            // Check sc_family at offset 1 (sc_len is at 0)
            let scFamily = sockaddrCtl.load(fromByteOffset: 1, as: UInt8.self)
            if scFamily != AF_SYSTEM {
                continue
            }

            // Log AF_SYSTEM sockets found
            let scLen = sockaddrCtl.load(fromByteOffset: 0, as: UInt8.self)
            let ssSysaddr = sockaddrCtl.load(fromByteOffset: 2, as: UInt16.self)
            let scIdVal = sockaddrCtl.load(fromByteOffset: 4, as: UInt32.self)
            let scUnit = sockaddrCtl.load(fromByteOffset: 8, as: UInt32.self)
            adapterLogger.info("findTunnelFileDescriptorTvOS: fd=\(fd) is AF_SYSTEM socket: len=\(scLen) sysaddr=\(ssSysaddr) sc_id=\(scIdVal) sc_unit=\(scUnit)")

            // Get ctl_id if we don't have it yet
            if ctlIdFound == 0 {
                let ioctlRet = ioctl(fd, CTLIOCGINFO, ctlInfo)
                if ioctlRet == 0 {
                    // ctl_id is at offset 0
                    ctlIdFound = ctlInfo.load(fromByteOffset: 0, as: UInt32.self)
                    adapterLogger.info("findTunnelFileDescriptorTvOS: Got ctl_id = \(ctlIdFound) from fd \(fd)")
                }
            }

            if ctlIdFound == 0 {
                continue
            }

            // Check sc_id at offset 4 (after sc_len[1], sc_family[1], ss_sysaddr[2])
            let scId = sockaddrCtl.load(fromByteOffset: 4, as: UInt32.self)
            if scId == ctlIdFound {
                adapterLogger.info("findTunnelFileDescriptorTvOS: Found utun FD = \(fd)")
                return fd
            }
        }

        adapterLogger.warning("findTunnelFileDescriptorTvOS: Could not find utun file descriptor")
        return nil
    }
    #endif
    
    private var stopCompletionHandler: (() -> Void)?
    
    // MARK: - Initialization

    /// Designated initializer.
    /// - Parameter packetTunnelProvider: an instance of `NEPacketTunnelProvider`. Internally stored
    ///   as a weak reference.
    /// - Returns: nil if the NetBird SDK client could not be initialized.
    init?(with tunnelManager: PacketTunnelProviderSettingsManager) {
        self.tunnelManager = tunnelManager
        self.networkChangeListener = NetworkChangeListener(with: tunnelManager)
        self.dnsManager = DNSManager(with: tunnelManager)

        let deviceName = Device.getName()
        let osVersion = Device.getOsVersion()
        let osName = Device.getOsName()

        #if os(tvOS)
        // On tvOS, the filesystem is blocked for the App Group container.
        // Create the client with empty paths and load config from local storage instead.
        guard let client = NetBirdSDKNewClient("", "", deviceName, osVersion, osName, self.networkChangeListener, self.dnsManager) else {
            adapterLogger.error("init: tvOS - Failed to create NetBird SDK client")
            return nil
        }
        self.client = client

        // Load config from extension-local storage (set via IPC from main app)
        // Note: Shared App Group UserDefaults does NOT work on tvOS between app and extension
        // due to sandbox restrictions. Config must be transferred via IPC.
        let configJSON: String? = UserDefaults.standard.string(forKey: "netbird_config_json_local")

        if let configJSON = configJSON {
            let updatedConfig = Self.updateDeviceNameInConfig(configJSON, newName: deviceName)
            do {
                try self.client.setConfigFromJSON(updatedConfig)
                adapterLogger.info("init: tvOS - loaded config successfully")
            } catch {
                adapterLogger.error("init: tvOS - failed to load config: \(error.localizedDescription)")
            }
        } else {
            adapterLogger.info("init: tvOS - no config found, client initialized without config")
        }
        #else
        guard let configPath = Preferences.configFile(), let statePath = Preferences.stateFile() else {
            adapterLogger.error("init: App group container unavailable - check entitlements")
            return nil
        }
        guard let client = NetBirdSDKNewClient(configPath, statePath, deviceName, osVersion, osName, self.networkChangeListener, self.dnsManager) else {
            adapterLogger.error("init: Failed to create NetBird SDK client with configPath=\(configPath), statePath=\(statePath)")
            return nil
        }
        self.client = client
        #endif
    }
    
    /// Returns the tunnel device interface name, or nil on error.
    /// - Returns: String.
    public var interfaceName: String? {
        guard let tunnelFileDescriptor = self.tunnelFileDescriptor else { return nil }

        var buffer = [UInt8](repeating: 0, count: Int(IFNAMSIZ))

        return buffer.withUnsafeMutableBufferPointer { mutableBufferPointer in
            guard let baseAddress = mutableBufferPointer.baseAddress else { return nil }

            var ifnameSize = socklen_t(IFNAMSIZ)
            let result = getsockopt(
                tunnelFileDescriptor,
                2 /* SYSPROTO_CONTROL */,
                2 /* UTUN_OPT_IFNAME */,
                baseAddress,
                &ifnameSize)

            if result == 0 {
                return String(cString: baseAddress)
            } else {
                return nil
            }
        }
    }
    
    public func start(completionHandler: @escaping (Error?) -> Void) {
        DispatchQueue.global().async {
            do {
                guard let fd = self.tunnelFileDescriptor, fd > 0 else {
                    adapterLogger.error("start: Invalid tunnel file descriptor (nil or 0) - cannot start VPN")
                    completionHandler(NSError(
                        domain: "io.netbird.NetbirdNetworkExtension",
                        code: 1004,
                        userInfo: [NSLocalizedDescriptionKey: "Invalid tunnel file descriptor. The VPN tunnel may not be properly configured."]
                    ))
                    return
                }
                let ifName = self.interfaceName ?? "unknown"

                let connectionListener = ConnectionListener(adapter: self, completionHandler: completionHandler)
                self.client.setConnectionListener(connectionListener)

                let envList = UserDefaults(suiteName: GlobalConstants.userPreferencesSuiteName).flatMap {
                    EnvVarPackager.getEnvironmentVariables(defaults: $0)
                }

                try self.client.run(fd, interfaceName: ifName, envList: envList)
            } catch {
                completionHandler(NSError(domain: "io.netbird.NetbirdNetworkExtension", code: 1001, userInfo: [NSLocalizedDescriptionKey: "Netbird client startup failed."]))
                self.stop()
            }
        }
    }
    
    public func needsLogin() -> Bool {
        return self.client.isLoginRequired()
    }

    /// Legacy synchronous login - returns URL string directly
    /// Used by iOS which opens Safari
    public func login() -> String {
        self.isExecutingLogin = true
        return self.client.loginForMobile()
    }

    /// New async login with device flow support
    /// - Parameters:
    ///   - forceDeviceAuth: If true, forces device code flow (for tvOS/Apple TV)
    ///   - onURL: Called when the auth URL is ready (includes user code for device flow)
    ///   - onSuccess: Called when login completes successfully
    ///   - onError: Called if login fails
    public func loginAsync(
        forceDeviceAuth: Bool,
        onURL: @escaping (String, String) -> Void,
        onSuccess: @escaping () -> Void,
        onError: @escaping (Error?) -> Void
    ) {
        self.isExecutingLogin = true

        // Track completion to prevent duplicate callbacks
        var completionCalled = false
        let completionLock = NSLock()

        // Keep a reference to the auth object so we can save config after login
        var authRef: NetBirdSDKAuth?

        let handleSuccess: () -> Void = { [weak self] in
            completionLock.lock()
            guard !completionCalled else {
                completionLock.unlock()
                return
            }
            completionCalled = true
            completionLock.unlock()

            // After successful login, save the config to persist credentials
            if let auth = authRef {
                var getConfigError: NSError?
                var configJSON = auth.getConfigJSON(&getConfigError)
                if getConfigError == nil && !configJSON.isEmpty {
                    #if os(tvOS)
                    let correctDeviceName = Device.getName()
                    configJSON = Self.updateDeviceNameInConfig(configJSON, newName: correctDeviceName)
                    #endif

                    _ = Preferences.saveConfigToUserDefaults(configJSON)
                }

                // Also try the file-based save (may fail on tvOS but works on iOS)
                let saveListener = LoginConfigSaveListener()
                auth.saveConfigIfSSOSupported(saveListener)
            }

            self?.lastLoginResult = "success"
            self?.lastLoginError = ""
            self?.isExecutingLogin = false
            self?.loginURLOpener = nil
            self?.loginErrListener = nil
            authRef = nil
            onSuccess()
        }

        let handleError: (Error?) -> Void = { [weak self] error in
            completionLock.lock()
            guard !completionCalled else {
                completionLock.unlock()
                return
            }
            completionCalled = true
            completionLock.unlock()

            self?.lastLoginResult = "error"
            self?.lastLoginError = error?.localizedDescription ?? "unknown"
            self?.isExecutingLogin = false
            self?.loginURLOpener = nil
            self?.loginErrListener = nil
            onError(error)
        }

        // Create URL opener
        let urlOpener = LoginURLOpener()
        urlOpener.onOpen = { url, userCode in
            DispatchQueue.main.async {
                onURL(url, userCode)
            }
        }
        urlOpener.onSuccess = {
            DispatchQueue.main.async {
                handleSuccess()
            }
        }

        // Create error listener
        let errListener = LoginErrListener()
        errListener.onSuccessCallback = {
            DispatchQueue.main.async {
                handleSuccess()
            }
        }
        errListener.onErrorCallback = { error in
            DispatchQueue.main.async {
                handleError(error)
            }
        }

        // Keep strong references during login
        self.loginURLOpener = urlOpener
        self.loginErrListener = errListener

        // Use default management URL for tvOS, empty for iOS (which handles it via ServerView)
        #if os(tvOS)
        // On tvOS, config is stored in extension-local UserDefaults (transferred via IPC from main app).
        // Note: Shared App Group UserDefaults does NOT work on tvOS due to sandbox restrictions.
        var managementURL = Self.defaultManagementURL

        let configJSON: String? = UserDefaults.standard.string(forKey: "netbird_config_json_local")

        if let configJSON = configJSON,
           let storedURL = Self.extractManagementURL(from: configJSON) {
            adapterLogger.info("loginAsync: Using management URL from config: \(storedURL, privacy: .public)")
            managementURL = storedURL
        } else {
            adapterLogger.info("loginAsync: No config found, using default management URL")
        }
        #else
        let managementURL = ""
        #endif

        // Get Auth object and call login
        #if os(tvOS)
        // On tvOS, config is stored in UserDefaults (not files) due to sandbox restrictions.
        // Pass empty path - the SDK will use setConfigFromJSON() instead.
        let configPath = ""
        #else
        guard let configPath = Preferences.configFile() else {
            handleError(NSError(domain: "io.netbird", code: 1003, userInfo: [NSLocalizedDescriptionKey: "App group container unavailable"]))
            return
        }
        #endif
        if let auth = NetBirdSDKNewAuth(configPath, managementURL, nil) {
            authRef = auth

            #if os(tvOS)
            let deviceName = Device.getName()
            auth.login(withDeviceName: errListener, urlOpener: urlOpener, forceDeviceAuth: forceDeviceAuth, deviceName: deviceName)
            #else
            auth.login(errListener, urlOpener: urlOpener, forceDeviceAuth: forceDeviceAuth)
            #endif
        } else {
            handleError(NSError(domain: "io.netbird", code: 1002, userInfo: [NSLocalizedDescriptionKey: "Failed to create Auth object"]))
        }
    }

    public func stop(completionHandler: (() -> Void)? = nil) {
        stopLock.lock()

        // Call any pending handler before setting a new one
        if let existingHandler = self.stopCompletionHandler {
            self.stopCompletionHandler = nil
            stopLock.unlock()
            existingHandler()
        } else {
            stopLock.unlock()
        }

        stopLock.lock()
        self.stopCompletionHandler = completionHandler
        stopLock.unlock()

        self.client.stop()

        // Fallback timeout (15 seconds) in case onDisconnected doesn't fire
        if completionHandler != nil {
            DispatchQueue.global().asyncAfter(deadline: .now() + 15) { [weak self] in
                self?.notifyStopCompleted()
            }
        }
    }

    func notifyStopCompleted() {
        stopLock.lock()

        guard let handler = self.stopCompletionHandler else {
            stopLock.unlock()
            return
        }

        self.stopCompletionHandler = nil
        stopLock.unlock()
        handler()
    }

    // MARK: - Config Helpers

    /// Extract the management URL from a config JSON string
    /// Returns nil if not found or empty
    static func extractManagementURL(from configJSON: String) -> String? {
        // Look for "ManagementURL":"..." pattern
        let pattern = "\"ManagementURL\"\\s*:\\s*\"([^\"]*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: configJSON, options: [], range: NSRange(configJSON.startIndex..., in: configJSON)),
              let urlRange = Range(match.range(at: 1), in: configJSON) else {
            return nil
        }
        let url = String(configJSON[urlRange])
        return url.isEmpty ? nil : url
    }

    /// Update the device name in a config JSON string
    static func updateDeviceNameInConfig(_ configJSON: String, newName: String) -> String {
        // Escape special characters for JSON string
        let escapedName = newName
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")

        let pattern = "\"DeviceName\"\\s*:\\s*\"[^\"]*\""
        let replacement = "\"DeviceName\":\"\(escapedName)\""

        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let range = NSRange(configJSON.startIndex..., in: configJSON)
            return regex.stringByReplacingMatches(in: configJSON, options: [], range: range, withTemplate: replacement)
        }

        return configJSON
    }
}
