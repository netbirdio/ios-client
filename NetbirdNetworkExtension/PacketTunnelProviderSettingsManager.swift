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
    private var interfaceIPv6: String?
    private var ipv4Routes: [NEIPv4Route]?
    private var ipv6Routes: [NEIPv6Route]?
    private var dnsSettings: NEDNSSettings?
    private var needFallbackNS: Bool = false
    private var containsDefaultRoute: Bool = false

    // Link-local dummy IPv6 used to satisfy NEIPv6Settings when the
    // interface has no IPv6 address but we still need a ::/0 blackhole route
    // to prevent IPv6 leaks while the IPv4 default route is in the tunnel.
    private static let ipv6BlackholeAddress = "fe80::1"
    private static let ipv6BlackholePrefix: NSNumber = 64

    init(with packetTunnelProvider: PacketTunnelProvider) {
        self.packetTunnelProvider = packetTunnelProvider
    }

    func setRoutes(v4Routes: [NEIPv4Route], v6Routes: [NEIPv6Route], containsDefault: Bool) {
            self.needFallbackNS = containsDefault
            self.containsDefaultRoute = containsDefault
            self.ipv4Routes = v4Routes
            self.ipv6Routes = v6Routes
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

        self.dnsSettings = dnsSettings
        self.updateTunnel()
    }
    
    func setInterfaceIP(interfaceIP: String) {
        self.interfaceIP = interfaceIP
    }

    func setInterfaceIPv6(interfaceIPv6: String) {
        self.interfaceIPv6 = interfaceIPv6
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
                
                var v6Addresses: [String] = []
                var v6PrefixLengths: [NSNumber] = []
                var v6Routes: [NEIPv6Route] = []

                if let ipv6CIDR = self.interfaceIPv6,
                   let (v6Addr, v6Prefix) = extractIPv6AddressAndPrefix(from: ipv6CIDR) {
                    v6Addresses.append(v6Addr)
                    v6PrefixLengths.append(NSNumber(value: v6Prefix))
                    v6Routes = self.ipv6Routes ?? []
                } else if self.containsDefaultRoute {
                    v6Addresses.append(Self.ipv6BlackholeAddress)
                    v6PrefixLengths.append(Self.ipv6BlackholePrefix)
                    v6Routes = [NEIPv6Route(destinationAddress: "::", networkPrefixLength: 0)]
                }

                let ipv6Settings = NEIPv6Settings(addresses: v6Addresses, networkPrefixLengths: v6PrefixLengths)
                if !v6Routes.isEmpty {
                    ipv6Settings.includedRoutes = v6Routes
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

    private func extractIPv6AddressAndPrefix(from cidr: String) -> (String, Int)? {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2,
              let prefix = Int(parts[1]) else {
            return nil
        }
        return (String(parts[0]), prefix)
    }

}
