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
            self.needFallbackNS = containsDefault
            self.ipv4Routes = v4Routes
            self.ipv6Routes = v6Routes
            self.updateTunnel()
    }
    
    func setDNS(config: HostDNSConfig) {
        var servers = [config.serverIP]
        if !config.routeAll && needFallbackNS{
            servers.append("1.1.1.1")
        }
        let dnsSettings = NEDNSSettings(servers: servers)
        if config.routeAll {
            dnsSettings.matchDomains = [""]
        } else {
            var searchDomains: [String] = []
            var matchDomains: [String] = []
            for domain in config.domains {
                if domain.disabled {
                    continue
                }
                matchDomains.append(domain.domain)
                if !domain.matchOnly {
                    searchDomains.append(domain.domain)
                }
            }
            dnsSettings.matchDomains = matchDomains
            dnsSettings.searchDomains = searchDomains
        }
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
            if let tunnelProvider = self.packetTunnelProvider {
                tunnelProvider.setTunnelSettings(tunnelNetworkSettings: tunnelSettings)
            } else {
                print("Failed to get tunnel provider")
            }
        } else {
            print("Failed to update tunnel")
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
