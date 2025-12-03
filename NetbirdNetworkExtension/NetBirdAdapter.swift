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

public class NetBirdAdapter {
    
    /// Packet tunnel provider.
    private weak var packetTunnelProvider: PacketTunnelProvider?
    
    private weak var tunnelManager: PacketTunnelProviderSettingsManager?
    
    public let client : NetBirdSDKClient
    private let networkChangeListener : NetworkChangeListener
    private let dnsManager: DNSManager
    
    public var isExecutingLogin = false
    
    var clientState : ClientState = .disconnected
            
    /// Tunnel device file descriptor.
    public var tunnelFileDescriptor: Int32? {
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
                return fd
            }
        }
        return nil
    }
    
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
        // Export env vars here.
        DispatchQueue.global().async {
            do {
                let connectionListener = ConnectionListener(adapter: self, completionHandler: completionHandler)
                self.client.setConnectionListener(connectionListener)
                
                let userDefaults = UserDefaults(suiteName: "group.io.netbird.app")
                let envList = userDefaults != nil ? EnvVarPackager.getEnvironmentVariables(defaults: userDefaults!) : nil
                
                try self.client.run(self.tunnelFileDescriptor ?? 0, interfaceName: self.interfaceName, envList: envList)
            } catch {
                completionHandler(NSError(domain: "io.netbird.NetbirdNetworkExtension", code: 1001, userInfo: [NSLocalizedDescriptionKey: "Netbird client startup failed."]))
                self.stop()
            }
        }
    }
    
    public func needsLogin() -> Bool {
        return self.client.isLoginRequired()
    }
    
    public func login() -> String {
        self.isExecutingLogin = true
        return self.client.loginForMobile()
    }
    
    public func stop() {
        self.client.stop()
    }
}
