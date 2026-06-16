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
            // [DEBUG exit-node-off] Log exactly what the core asks us to install.
            // Compare this against the "createTunnelSettings" line to see whether the
            // default route is correctly dropped from includedRoutes when the exit
            // node is turned off.
            let v4Desc = v4Routes.map { "\($0.destinationAddress)/\($0.destinationSubnetMask)" }.joined(separator: " ")
            let v6Desc = v6Routes.map { "\($0.destinationAddress)/\($0.destinationNetworkPrefixLength)" }.joined(separator: " ")
            AppLogger.shared.log("[DEBUG exit-node-off] setRoutes: containsDefault=\(containsDefault) v4(\(v4Routes.count))=[\(v4Desc)] v6(\(v6Routes.count))=[\(v6Desc)]")

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
        // [DEBUG exit-node-off] Track interface address changes. interfaceIPv6 is
        // never cleared once set (see NetworkChangeListener), so a stale v6 address
        // surviving a profile switch would show up by comparing these lines.
        AppLogger.shared.log("[DEBUG exit-node-off] setInterfaceIP: \(interfaceIP) (prev=\(self.interfaceIP ?? "nil"))")
        self.interfaceIP = interfaceIP
    }

    func setInterfaceIPv6(interfaceIPv6: String) {
        AppLogger.shared.log("[DEBUG exit-node-off] setInterfaceIPv6: \(interfaceIPv6) (prev=\(self.interfaceIPv6 ?? "nil"))")
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

                if !v6Addresses.isEmpty {
                    let ipv6Settings = NEIPv6Settings(addresses: v6Addresses, networkPrefixLengths: v6PrefixLengths)
                    if !v6Routes.isEmpty {
                        ipv6Settings.includedRoutes = v6Routes
                    }
                    tunnelNetworkSettings.ipv6Settings = ipv6Settings
                }
                
                tunnelNetworkSettings.mtu = 1280

                if self.dnsSettings != nil {
                    tunnelNetworkSettings.dnsSettings = self.dnsSettings
                }

                // [DEBUG exit-node-off] This is the single most important line for
                // the "exit node off -> no connectivity" bug: it shows the exact
                // includedRoutes that iOS will install. If a v4 0.0.0.0/0 (or a v6
                // ::/0 that isn't the intended blackhole) is still present here while
                // the exit node is OFF, all internet traffic is funneled into the
                // tunnel with no way out (black hole). Cross-check with the core's
                // "Calling remove for key 0.0.0.0/0" in client.log.
                let v4Included = (ipv4Settings.includedRoutes ?? []).map { "\($0.destinationAddress)/\($0.destinationSubnetMask)" }.joined(separator: " ")
                let v6Included = v6Routes.map { "\($0.destinationAddress)/\($0.destinationNetworkPrefixLength)" }.joined(separator: " ")
                let v6AddrDesc = zip(v6Addresses, v6PrefixLengths).map { "\($0)/\($1)" }.joined(separator: " ")
                let matchDomains = (self.dnsSettings?.matchDomains ?? []).map { $0.isEmpty ? "<root \"\">" : $0 }.joined(separator: ",")
                let dnsServers = (self.dnsSettings?.servers ?? []).joined(separator: ",")
                AppLogger.shared.log("[DEBUG exit-node-off] createTunnelSettings: containsDefaultRoute=\(self.containsDefaultRoute) v4addr=\(ipAddress)/\(subnetMask) v4Included=[\(v4Included)] v6addr=[\(v6AddrDesc)] v6Included=[\(v6Included)] dnsServers=[\(dnsServers)] matchDomains=[\(matchDomains)]")

                return tunnelNetworkSettings
            }
        }

        // [DEBUG exit-node-off] interfaceIP missing or unparseable -> settings not
        // updated, the previous (possibly default-routed) settings stay in effect.
        AppLogger.shared.log("[DEBUG exit-node-off] createTunnelSettings: returning nil (interfaceIP=\(self.interfaceIP ?? "nil")), tunnel settings NOT updated")
        return nil
    }

    private func extractIPv6AddressAndPrefix(from cidr: String) -> (String, Int)? {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2,
              let prefix = Int(parts[1]),
              (0...128).contains(prefix) else {
            return nil
        }
        return (String(parts[0]), prefix)
    }

}
