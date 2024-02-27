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
    private var routes: [NEIPv4Route]?
    private var dnsSettings: NEDNSSettings?
    
    init(with packetTunnelProvider: PacketTunnelProvider) {
        self.packetTunnelProvider = packetTunnelProvider
    }
    
    func setRoutes(routes: [NEIPv4Route]) {
        self.routes = routes
        self.updateTunnel()
    }
    
    func setDNS(config: HostDNSConfig) {
        let dnsSettings = NEDNSSettings(servers: [config.serverIP])
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
            self.packetTunnelProvider!.setTunnelSettings(tunnelNetworkSettings: tunnelSettings)
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
                
                if self.routes != nil {
                    ipv4Settings.includedRoutes = self.routes
                }
                tunnelNetworkSettings.ipv4Settings = ipv4Settings
                
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
