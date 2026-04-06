//
//  PacketTunnelProviderSettingsManager.swift
//  NetBirdiOS
//
//  Created by Pascal Fischer on 06.10.23.
//

import Foundation
import NetworkExtension

class PacketTunnelProviderSettingsManager {
    
    private weak var packetTunnelProvider: PacketTunnelProvider?
    
    private var interfaceIP: String?
    private var ipv4Routes: [NEIPv4Route]?
    private var ipv6Routes: [NEIPv6Route]?
    private var dnsSettings: NEDNSSettings?
    private var needFallbackNS: Bool = false
    
    init(with packetTunnelProvider: PacketTunnelProvider) {
        self.packetTunnelProvider = packetTunnelProvider
    }
    
    func setRoutes(v4Routes: [NEIPv4Route], v6Routes: [NEIPv6Route], containsDefault: Bool) {
            let prev = self.needFallbackNS
            self.needFallbackNS = containsDefault
            self.ipv4Routes = v4Routes
            self.ipv6Routes = v6Routes
            AppLogger.shared.log("setRoutes: v4=\(v4Routes.count) v6=\(v6Routes.count) containsDefault=\(containsDefault) needFallbackNS: \(prev)->\(containsDefault)")
            self.updateTunnel()
    }

    func setDNS(config: HostDNSConfig) {
        let dnsSettings = NEDNSSettings(servers: [config.serverIP])

        // Always route all DNS through the tunnel on iOS.
        // The Go DNS server has a root zone fallback handler that forwards
        // unmatched queries to host DNS servers (e.g. 1.1.1.1).
        // This avoids DNS failures when exit node routes (0.0.0.0/0) are
        // added or removed, as iOS system DNS on cellular is unreliable
        // with an active VPN tunnel.
        dnsSettings.matchDomains = [""]

        var searchDomains: [String] = []
        for domain in config.domains {
            if !domain.disabled && !domain.matchOnly {
                searchDomains.append(domain.domain)
            }
        }
        if !searchDomains.isEmpty {
            dnsSettings.searchDomains = searchDomains
        }

        AppLogger.shared.log("setDNS: server=\(config.serverIP) matchDomains=[\"\"] searchDomains=\(searchDomains) (mgmt routeAll=\(config.routeAll) domains=\(config.domains.count))")
        self.dnsSettings = dnsSettings
        self.updateTunnel()
    }
    
    func setInterfaceIP(interfaceIP: String) {
        self.interfaceIP = interfaceIP
    }
    
    func getInterfaceIP() -> String? {
        return self.interfaceIP
    }
    
    private func updateTunnel() {
        if let tunnelSettings = createTunnelSettings() {
            AppLogger.shared.log("updateTunnel: dns=\(tunnelSettings.dnsSettings?.servers ?? []) matchDomains=\(tunnelSettings.dnsSettings?.matchDomains ?? []) v4Routes=\(tunnelSettings.ipv4Settings?.includedRoutes?.count ?? 0)")
            if let tunnelProvider = self.packetTunnelProvider {
                tunnelProvider.setTunnelSettings(tunnelNetworkSettings: tunnelSettings)
            } else {
                AppLogger.shared.log("updateTunnel: tunnel provider is nil")
            }
        } else {
            AppLogger.shared.log("updateTunnel: failed to create settings")
        }
    }
    
    private func createTunnelSettings() -> NEPacketTunnelNetworkSettings? {
        if let interfaceIP = interfaceIP {
            if let (ipAddress, subnetMask) = extractIPAddressAndSubnet(from: interfaceIP) {
                let tunnelNetworkSettings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: ipAddress)
                let ipv4Settings = NEIPv4Settings(addresses: [ipAddress], subnetMasks: [subnetMask])
                
                ipv4Settings.includedRoutes = [ NEIPv4Route(destinationAddress: ipAddress, subnetMask: subnetMask) ]
                
                if self.ipv4Routes != nil {
                    ipv4Settings.includedRoutes = self.ipv4Routes
                }
                tunnelNetworkSettings.ipv4Settings = ipv4Settings
                
                let ipv6Settings = NEIPv6Settings(addresses: [], networkPrefixLengths: [])
                
                if self.ipv6Routes != nil {
                    ipv6Settings.includedRoutes = self.ipv6Routes
                }
                
                tunnelNetworkSettings.ipv6Settings = ipv6Settings
                
                tunnelNetworkSettings.mtu = 1280
                
                if self.dnsSettings != nil {
                    tunnelNetworkSettings.dnsSettings = self.dnsSettings
                }
                
                return tunnelNetworkSettings
            }
        }
        
        return nil
    }
    
}
