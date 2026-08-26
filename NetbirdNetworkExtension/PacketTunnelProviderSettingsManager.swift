//
//  PacketTunnelProviderSettingsManager.swift
//  NetBirdiOS
//
//  Created by Pascal Fischer on 06.10.23.
//

import Foundation
import NetworkExtension

enum IPv6ClearMode: String {
    case explicitNil
    case emptyAddrs
    case dummyEmptyRt
    case dummyExcluded

    static let active = IPv6ClearMode(rawValue: ProcessInfo.processInfo.environment["NB_IPV6_CLEAR_MODE"] ?? "") ?? .dummyEmptyRt
}

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
        // A new engine session always pushes setInterfaceIP first, then setInterfaceIPv6
        // only when the session actually has a v6 address. Drop any previous session's v6
        // here so a v4-only session (IPv6 disabled or a v4-only profile) can't keep applying
        // a stale interfaceIPv6 — which would send createTunnelSettings down the dual-stack
        // branch and skip the ::/0 blackhole, leaking IPv6 past a selected exit node. This
        // manager outlives individual engine sessions (it is owned by the extension process),
        // so the reset has to happen at the session boundary rather than on teardown.
        self.interfaceIPv6 = nil
    }

    func setInterfaceIPv6(interfaceIPv6: String) {
        self.interfaceIPv6 = interfaceIPv6
    }

    func getInterfaceIP() -> String? {
        return self.interfaceIP
    }
    
    private func updateTunnel() {
        AppLogger.shared.log("updateTunnel: interfaceIP=\(interfaceIP ?? "nil") interfaceIPv6=\(interfaceIPv6 ?? "nil") containsDefaultRoute=\(containsDefaultRoute) v4RouteCount=\(ipv4Routes?.count ?? -1) v6RouteCount=\(ipv6Routes?.count ?? -1) clearMode=\(IPv6ClearMode.active.rawValue)")
        if let tunnelSettings = createTunnelSettings() {
            if let tunnelProvider = self.packetTunnelProvider {
                AppLogger.shared.log("updateTunnel: applying -> \(Self.describe(tunnelSettings))")
                tunnelProvider.setTunnelSettings(tunnelNetworkSettings: tunnelSettings)
            } else {
                AppLogger.shared.log("updateTunnel: failed to get tunnel provider")
                print("Failed to get tunnel provider")
            }
        } else {
            AppLogger.shared.log("updateTunnel: createTunnelSettings returned nil")
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
                    AppLogger.shared.log("createTunnelSettings: v6 branch=ACTIVE (address present)")
                } else {
                    // Always assign IPv6 settings explicitly: leaving the property nil
                    // makes setTunnelNetworkSettings KEEP the previously applied IPv6
                    // config, so the ::/0 blackhole installed while an exit node was
                    // selected would linger after deselect and keep black-holing traffic.
                    switch IPv6ClearMode.active {
                    case .explicitNil:
                        AppLogger.shared.log("createTunnelSettings: v6 branch=CLEAR mode=explicitNil (ipv6Settings left nil)")

                    case .emptyAddrs:
                        AppLogger.shared.log("createTunnelSettings: v6 branch=CLEAR mode=emptyAddrs (constructing NEIPv6Settings with empty arrays)")
                        tunnelNetworkSettings.ipv6Settings = NEIPv6Settings(addresses: [], networkPrefixLengths: [])
                        AppLogger.shared.log("createTunnelSettings: v6 branch=CLEAR mode=emptyAddrs constructed OK")

                    case .dummyEmptyRt:
                        let ipv6Settings = NEIPv6Settings(addresses: [Self.ipv6BlackholeAddress], networkPrefixLengths: [Self.ipv6BlackholePrefix])
                        // Explicitly clear any previously-applied IPv6 routes.
                        ipv6Settings.includedRoutes = []
                        tunnelNetworkSettings.ipv6Settings = ipv6Settings
                        AppLogger.shared.log("createTunnelSettings: v6 branch=CLEAR mode=dummyEmptyRt")

                    case .dummyExcluded:
                        let ipv6Settings = NEIPv6Settings(addresses: [Self.ipv6BlackholeAddress], networkPrefixLengths: [Self.ipv6BlackholePrefix])
                        ipv6Settings.includedRoutes = []
                        ipv6Settings.excludedRoutes = [NEIPv6Route.default()]
                        tunnelNetworkSettings.ipv6Settings = ipv6Settings
                        AppLogger.shared.log("createTunnelSettings: v6 branch=CLEAR mode=dummyExcluded")
                    }
                }
                
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
              let prefix = Int(parts[1]),
              (0...128).contains(prefix) else {
            return nil
        }
        return (String(parts[0]), prefix)
    }

    private static func describe(_ settings: NEPacketTunnelNetworkSettings) -> String {
        var out: [String] = []

        if let v4 = settings.ipv4Settings {
            out.append("v4[addrs=\(v4.addresses) masks=\(v4.subnetMasks) incl=\(describeV4(v4.includedRoutes)) excl=\(describeV4(v4.excludedRoutes))]")
        } else {
            out.append("v4[nil]")
        }

        if let v6 = settings.ipv6Settings {
            out.append("v6[addrs=\(v6.addresses) prefixes=\(v6.networkPrefixLengths) incl=\(describeV6(v6.includedRoutes)) excl=\(describeV6(v6.excludedRoutes))]")
        } else {
            out.append("v6[NIL <- property not set]")
        }

        if let dns = settings.dnsSettings {
            out.append("dns[servers=\(dns.servers) match=\(dns.matchDomains ?? []) search=\(dns.searchDomains ?? [])]")
        } else {
            out.append("dns[nil]")
        }

        out.append("mtu=\(settings.mtu?.stringValue ?? "nil")")

        return out.joined(separator: " ")
    }

    private static func describeV4(_ routes: [NEIPv4Route]?) -> String {
        guard let routes = routes else {
            return "NIL"
        }
        if routes.isEmpty {
            return "EMPTY_ARRAY"
        }
        return routes.map { "\($0.destinationAddress)/\($0.destinationSubnetMask)" }.joined(separator: ",")
    }

    private static func describeV6(_ routes: [NEIPv6Route]?) -> String {
        guard let routes = routes else {
            return "NIL"
        }
        if routes.isEmpty {
            return "EMPTY_ARRAY"
        }
        return routes.map { "\($0.destinationAddress)/\($0.destinationNetworkPrefixLength)" }.joined(separator: ",")
    }

}
