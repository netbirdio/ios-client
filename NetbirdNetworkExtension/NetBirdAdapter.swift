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

// MARK: - URL Opener for Login Flow
/// Handles OAuth URL opening and login success callbacks
class LoginURLOpener: NSObject, NetBirdSDKURLOpenerProtocol {
    /// Callback when URL needs to be opened (with user code for device flow)
    var onOpen: ((String, String) -> Void)?
    /// Callback when login succeeds
    var onSuccess: (() -> Void)?

    func open(_ url: String?, userCode: String?) {
        adapterLogger.info("LoginURLOpener.open() called with url=\(url ?? "nil", privacy: .public), userCode=\(userCode ?? "nil", privacy: .public)")
        guard let url = url else { return }
        onOpen?(url, userCode ?? "")
    }

    func onLoginSuccess() {
        adapterLogger.info("LoginURLOpener.onLoginSuccess() called!")
        print(">>> LoginURLOpener.onLoginSuccess() called! <<<")
        onSuccess?()
    }
}

// MARK: - Error Listener for Async Operations
/// Handles error callbacks from async SDK operations
class LoginErrListener: NSObject, NetBirdSDKErrListenerProtocol {
    var onErrorCallback: ((Error?) -> Void)?
    var onSuccessCallback: (() -> Void)?

    func onError(_ err: Error?) {
        adapterLogger.error("LoginErrListener.onError() called with: \(err?.localizedDescription ?? "nil", privacy: .public)")
        print(">>> LoginErrListener.onError() called with: \(err?.localizedDescription ?? "nil") <<<")
        onErrorCallback?(err)
    }

    func onSuccess() {
        // SDK calls this when the operation succeeds (e.g., device auth completed)
        // This is NOT an error - call the success handler
        adapterLogger.info("LoginErrListener.onSuccess() called!")
        print(">>> LoginErrListener.onSuccess() called! <<<")
        onSuccessCallback?()
    }
}

// MARK: - SSO Listener for Config Save
/// Used to save config after successful login
class LoginConfigSaveListener: NSObject, NetBirdSDKSSOListenerProtocol {
    var onResult: ((Bool?, Error?) -> Void)?

    func onSuccess(_ ssoSupported: Bool) {
        adapterLogger.info("LoginConfigSaveListener.onSuccess() called with ssoSupported=\(ssoSupported)")
        onResult?(ssoSupported, nil)
    }

    func onError(_ error: Error?) {
        adapterLogger.error("LoginConfigSaveListener.onError() called with: \(error?.localizedDescription ?? "nil", privacy: .public)")
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

    var clientState : ClientState = .disconnected
            
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
        let AF_SYS_CONTROL: UInt16 = 2
        let SYSPROTO_CONTROL: Int32 = 2
        let UTUN_OPT_IFNAME: Int32 = 2
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
        ctlName.withCString { cstr in
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
    
    // MARK: - Initialization

    /// Designated initializer.
    /// - Parameter packetTunnelProvider: an instance of `NEPacketTunnelProvider`. Internally stored
    ///   as a weak reference.
    init(with tunnelManager: PacketTunnelProviderSettingsManager) {
        self.tunnelManager = tunnelManager
        self.networkChangeListener = NetworkChangeListener(with: tunnelManager)
        self.dnsManager = DNSManager(with: tunnelManager)
        self.client = NetBirdSDKNewClient(Preferences.configFile(), Preferences.stateFile(), Device.getName(), Device.getOsVersion(), Device.getOsName(), self.networkChangeListener, self.dnsManager)!
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
                let fd = self.tunnelFileDescriptor ?? 0
                let ifName = self.interfaceName ?? "unknown"
                adapterLogger.info("start: tunnelFileDescriptor = \(fd), interfaceName = \(ifName, privacy: .public)")

                if fd == 0 {
                    adapterLogger.error("start: WARNING - File descriptor is 0, WireGuard may not work properly!")
                }

                let connectionListener = ConnectionListener(adapter: self, completionHandler: completionHandler)
                self.client.setConnectionListener(connectionListener)
                adapterLogger.info("start: Calling client.run() with fd=\(fd), interfaceName=\(ifName, privacy: .public)")
                try self.client.run(fd, interfaceName: ifName)
            } catch {
                adapterLogger.error("start: client.run() failed: \(error.localizedDescription, privacy: .public)")
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
        adapterLogger.info("loginAsync: Starting async login with forceDeviceAuth=\(forceDeviceAuth)")
        self.isExecutingLogin = true

        // Track completion to prevent duplicate callbacks
        // Both urlOpener.onLoginSuccess and errListener.onSuccess might be called
        var completionCalled = false
        let completionLock = NSLock()

        // Keep a reference to the auth object so we can save config after login
        var authRef: NetBirdSDKAuth?

        let handleSuccess: () -> Void = { [weak self] in
            adapterLogger.info("loginAsync: handleSuccess called")
            completionLock.lock()
            guard !completionCalled else {
                completionLock.unlock()
                adapterLogger.info("loginAsync: Success already handled, ignoring duplicate")
                return
            }
            completionCalled = true
            completionLock.unlock()

            adapterLogger.info("loginAsync: Login succeeded, now saving config...")

            // After successful login, save the config to persist credentials
            // The Auth.login() may authenticate but not write to disk
            if let auth = authRef {
                // First, try to get config JSON and save to UserDefaults
                // This is the tvOS-compatible storage that works when file writes fail
                var getConfigError: NSError?
                let configJSON = auth.getConfigJSON(&getConfigError)
                if let error = getConfigError {
                    adapterLogger.error("loginAsync: Failed to get config JSON: \(error.localizedDescription, privacy: .public)")
                } else if !configJSON.isEmpty {
                    adapterLogger.info("loginAsync: Got config JSON (\(configJSON.count) bytes), saving to UserDefaults")
                    if Preferences.saveConfigToUserDefaults(configJSON) {
                        adapterLogger.info("loginAsync: Config saved to UserDefaults successfully")
                    } else {
                        adapterLogger.error("loginAsync: Failed to save config to UserDefaults")
                    }
                } else {
                    adapterLogger.warning("loginAsync: getConfigJSON returned empty string")
                }

                // Also try the file-based save (may fail on tvOS but works on iOS)
                let saveListener = LoginConfigSaveListener()
                saveListener.onResult = { success, error in
                    if let error = error {
                        adapterLogger.error("loginAsync: Failed to save config to file after login: \(error.localizedDescription, privacy: .public)")
                    } else {
                        adapterLogger.info("loginAsync: Config saved to file successfully after login, ssoSupported=\(success ?? false)")
                    }
                }
                auth.saveConfigIfSSOSupported(saveListener)
            }

            adapterLogger.info("loginAsync: Setting isExecutingLogin=false and calling onSuccess callback")
            self?.lastLoginResult = "success"
            self?.lastLoginError = ""
            self?.isExecutingLogin = false
            self?.loginURLOpener = nil
            self?.loginErrListener = nil
            authRef = nil
            onSuccess()
        }

        let handleError: (Error?) -> Void = { [weak self] error in
            adapterLogger.error("loginAsync: handleError called with: \(error?.localizedDescription ?? "nil", privacy: .public)")
            completionLock.lock()
            guard !completionCalled else {
                completionLock.unlock()
                adapterLogger.info("loginAsync: Completion already handled, ignoring error")
                return
            }
            completionCalled = true
            completionLock.unlock()

            adapterLogger.info("loginAsync: Setting isExecutingLogin=false and calling onError callback")
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
            // Go SDK calls this from a goroutine - dispatch to main thread
            DispatchQueue.main.async {
                onURL(url, userCode)
            }
        }
        urlOpener.onSuccess = {
            // Go SDK calls this from a goroutine - dispatch to main thread
            DispatchQueue.main.async {
                adapterLogger.info("loginAsync: urlOpener.onLoginSuccess called via onSuccess closure")
                handleSuccess()
            }
        }

        // Create error listener
        // Note: The SDK's ErrListener protocol has both onSuccess() and onError()
        // onSuccess() is called when device auth completes successfully via this listener
        let errListener = LoginErrListener()
        errListener.onSuccessCallback = {
            // Go SDK calls this from a goroutine - dispatch to main thread
            // This is called when the device auth polling succeeds
            DispatchQueue.main.async {
                adapterLogger.info("loginAsync: errListener.onSuccessCallback called")
                handleSuccess()
            }
        }
        errListener.onErrorCallback = { error in
            // Go SDK calls this from a goroutine - dispatch to main thread
            DispatchQueue.main.async {
                adapterLogger.error("loginAsync: errListener.onErrorCallback called with: \(error?.localizedDescription ?? "nil", privacy: .public)")
                handleError(error)
            }
        }

        // Keep strong references during login
        self.loginURLOpener = urlOpener
        self.loginErrListener = errListener

        // Use default management URL for tvOS, empty for iOS (which handles it via ServerView)
        #if os(tvOS)
        let managementURL = Self.defaultManagementURL
        #else
        let managementURL = ""
        #endif

        adapterLogger.info("loginAsync: Creating Auth object with configFile=\(Preferences.configFile(), privacy: .public), managementURL=\(managementURL, privacy: .public)")

        // Get Auth object and call login
        if let auth = NetBirdSDKNewAuth(Preferences.configFile(), managementURL, nil) {
            // Store reference so handleSuccess can save config
            authRef = auth
            adapterLogger.info("loginAsync: Auth object created, calling auth.login()")
            auth.login(errListener, urlOpener: urlOpener, forceDeviceAuth: forceDeviceAuth)
            adapterLogger.info("loginAsync: auth.login() returned (async operation started)")
        } else {
            adapterLogger.error("loginAsync: Failed to create Auth object")
            handleError(NSError(domain: "io.netbird", code: 1002, userInfo: [NSLocalizedDescriptionKey: "Failed to create Auth object"]))
        }
    }

    public func stop() {
        self.client.stop()
    }
}
