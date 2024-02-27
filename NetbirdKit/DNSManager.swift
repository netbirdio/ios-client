//
//  DNSHostManager.swift
//  NetBirdiOS
//
//  Created by Pascal Fischer on 06.10.23.
//

import Foundation

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
    
    private weak var tunnelManager: PacketTunnelProviderSettingsManager?
    
    init(with tunnelManager: PacketTunnelProviderSettingsManager) {
        self.tunnelManager = tunnelManager
    }
    
    func applyDns(_ p0: String?) {
        if let p0 = p0, !p0.isEmpty {
            if let config = parseDNSSettingsString(inputString: p0) {
                self.tunnelManager?.setDNS(config: config)
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
