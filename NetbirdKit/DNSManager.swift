//
//  DNSHostManager.swift
//  NetBirdiOS
//
//  Created by Pascal Fischer on 06.10.23.
//

import Foundation
import NetBirdSDK

struct DomainConfig: Codable {
    var disabled: Bool
    var domain: String
    var matchOnly: Bool
}

struct HostDNSConfig: Codable {
    var domains: [DomainConfig]
    var routeAll: Bool
    var serverIP: String
    var serverPort: Int
}

class DNSManager: NSObject, NetBirdSDKDnsManagerProtocol {

    // See NetworkChangeListener for the full rationale: the Go engine retains this
    // manager for the SDK client's lifetime and can fire applyDns late, after the
    // adapter has been swapped/torn down. Guard against dereferencing a freed
    // tunnelManager (EXC_BAD_ACCESS / 0x28) and serialize with invalidate().
    private let callbackQueue = DispatchQueue(label: "io.netbird.DNSManager")
    private var isValid = true

    private var tunnelManager: PacketTunnelProviderSettingsManager?

    init(with tunnelManager: PacketTunnelProviderSettingsManager) {
        self.tunnelManager = tunnelManager
    }

    /// Detach from the tunnel manager. After this call every Go callback is dropped.
    /// Must be called before the owning adapter/provider is torn down.
    func invalidate() {
        callbackQueue.sync {
            self.isValid = false
            self.tunnelManager = nil
        }
    }

    func applyDns(_ p0: String?) {
        callbackQueue.sync {
            guard self.isValid, let tunnelManager = self.tunnelManager else {
                return
            }
            if let p0 = p0, !p0.isEmpty {
                if let config = parseDNSSettingsString(inputString: p0) {
                    tunnelManager.setDNS(config: config)
                }
            }
        }
    }
    
    func parseDNSSettingsString(inputString: String) -> HostDNSConfig? {
        guard let jsonData = inputString.data(using: .utf8) else { return nil }
            do {
                let config = try JSONDecoder().decode(HostDNSConfig.self, from: jsonData)
                return config
            } catch {
                print(error)
            }
        return nil
    }
    
}
