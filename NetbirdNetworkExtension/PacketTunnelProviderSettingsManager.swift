//
//  PacketTunnelProviderSettingsManager.swift
//  NetBirdiOS
//
//  Created by Pascal Fischer on 06.10.23.
//

import Foundation
import Network
import NetworkExtension

// Diagnostics only. Reads back what the system actually did with the settings we
// handed to setTunnelNetworkSettings, so a run can distinguish "we asked for the
// wrong thing" from "we asked correctly and iOS kept the old state". Lives in
// this file rather than its own so no Xcode target membership has to change.
enum TunnelStateProbe {

    static func snapshot(_ tag: String) {
        AppLogger.shared.log("PROBE[\(tag)]: ifaces: \(interfaceSummary())")
        AppLogger.shared.log("PROBE[\(tag)]: v6routes: \(routeSummary(family: AF_INET6))")
        AppLogger.shared.log("PROBE[\(tag)]: v4routes: \(routeSummary(family: AF_INET))")
        AppLogger.shared.log("PROBE[\(tag)]: v6reach: \(reachabilitySummary())")
    }

    static func snapshotAfterSettle(_ tag: String) {
        snapshot("\(tag)+0s")
        DispatchQueue.global().asyncAfter(deadline: .now() + 3.0) {
            snapshot("\(tag)+3s")
        }
    }

    private static func interfaceSummary() -> String {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else {
            return "getifaddrs failed errno=\(errno)"
        }
        defer { freeifaddrs(head) }

        var addrs: [String: [String]] = [:]
        var flags: [String: UInt32] = [:]

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let namePtr = ifa.ifa_name else { continue }
            let name = String(cString: namePtr)
            flags[name] = ifa.ifa_flags

            guard let sa = ifa.ifa_addr else { continue }
            let family = sa.pointee.sa_family
            guard family == UInt8(AF_INET) || family == UInt8(AF_INET6) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else {
                continue
            }
            var text = String(cString: host)
            if let pct = text.firstIndex(of: "%") {
                text = String(text[text.startIndex..<pct])
            }
            let tag = family == UInt8(AF_INET6) ? "v6" : "v4"
            addrs[name, default: []].append("\(tag) \(text)")
        }

        let interesting = addrs.keys.filter {
            $0.hasPrefix("utun") || $0.hasPrefix("en") || $0.hasPrefix("pdp_ip") || $0.hasPrefix("ipsec")
        }.sorted()

        return interesting.map { name in
            let list = (addrs[name] ?? []).sorted().joined(separator: " ")
            let up = ((flags[name] ?? 0) & UInt32(IFF_UP)) != 0 ? "UP" : "DOWN"
            return "\(name)[\(up) \(list.isEmpty ? "no-addr" : list)]"
        }.joined(separator: " | ")
    }

    // Darwin's <net/route.h> types are not surfaced to Swift, so the header
    // layout is restated here to read the sysctl dump.
    private struct RouteMsgHeader {
        var msglen: UInt16 = 0
        var version: UInt8 = 0
        var type: UInt8 = 0
        var index: UInt16 = 0
        var flags: Int32 = 0
        var addrs: Int32 = 0

        init(buf: [UInt8], offset: Int) {
            func u16(_ at: Int) -> UInt16 {
                UInt16(buf[at]) | (UInt16(buf[at + 1]) << 8)
            }
            func i32(_ at: Int) -> Int32 {
                var v: UInt32 = 0
                for i in 0..<4 {
                    v |= UInt32(buf[at + i]) << (8 * UInt32(i))
                }
                return Int32(bitPattern: v)
            }
            msglen = u16(offset)
            version = buf[offset + 2]
            type = buf[offset + 3]
            index = u16(offset + 4)
            // offset+6..7 is rtm_pad/reserved on Darwin; flags follow at +8.
            flags = i32(offset + 8)
            addrs = i32(offset + 12)
        }

        static let size = 92
        static let addrsStart = 92
    }

    // Walks the kernel routing table via sysctl(NET_RT_DUMP). This is the only
    // way to see whether the ::/0 route we asked to drop is actually gone --
    // the completion handler of setTunnelNetworkSettings says nothing about it.
    private static func routeSummary(family: Int32) -> String {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, family, NET_RT_DUMP, 0]
        var size = 0
        if sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) != 0 {
            return "sysctl sizing failed errno=\(errno)"
        }
        var buf = [UInt8](repeating: 0, count: size)
        if sysctl(&mib, u_int(mib.count), &buf, &size, nil, 0) != 0 {
            return "sysctl dump failed errno=\(errno)"
        }

        var lines: [String] = []
        var offset = 0
        while offset + RouteMsgHeader.size <= size {
            let hdr = RouteMsgHeader(buf: buf, offset: offset)
            let msgLen = Int(hdr.msglen)
            guard msgLen > RouteMsgHeader.size, offset + msgLen <= size else { break }
            if let line = describeRoute(buf: buf, start: offset, msgLen: msgLen, hdr: hdr) {
                lines.append(line)
            }
            offset += msgLen
        }

        if lines.isEmpty {
            return "none"
        }
        // A full table is long; the default routes are what this investigation
        // turns on, so surface them first and cap the rest.
        let defaults = lines.filter { $0.hasPrefix("::/0 ") || $0.hasPrefix("0.0.0.0/0 ") }
        let others = lines.filter { !$0.hasPrefix("::/0 ") && !$0.hasPrefix("0.0.0.0/0 ") }
        let capped = Array(others.prefix(20))
        let suffix = others.count > capped.count ? " (+\(others.count - capped.count) more)" : ""
        return (defaults + capped).joined(separator: ", ") + suffix
    }

    private static func describeRoute(buf: [UInt8], start: Int, msgLen: Int, hdr: RouteMsgHeader) -> String? {
        var cursor = start + RouteMsgHeader.addrsStart
        let end = start + msgLen

        var dest: String?
        var gateway: String?
        var maskBits: Int?

        // RTAX_DST/GATEWAY/NETMASK are 0/1/2 in the fixed RTA_* bit order.
        for bit in 0..<8 {
            guard hdr.addrs & (1 << Int32(bit)) != 0 else { continue }
            guard cursor + 2 <= end else { break }

            let saLen = Int(buf[cursor])
            let saFamily = buf[cursor + 1]
            let advance = saLen == 0 ? 4 : (saLen + 3) & ~3
            let base = cursor
            cursor += advance
            guard saLen > 0 else { continue }

            if bit == 0 {
                dest = addressText(buf: buf, offset: base, family: saFamily)
            } else if bit == 1 {
                gateway = addressText(buf: buf, offset: base, family: saFamily)
            } else if bit == 2 {
                maskBits = maskPrefix(buf: buf, offset: base, saLen: saLen)
            }
        }

        guard var text = dest else { return nil }
        if let bits = maskBits {
            text += "/\(bits)"
        } else if text == "::" || text == "0.0.0.0" {
            text += "/0"
        }

        let via = gateway.map { " via \($0)" } ?? ""
        return "\(text)\(via) dev \(interfaceName(index: Int(hdr.index))) \(routeFlagText(hdr.flags))"
    }

    private static func addressText(buf: [UInt8], offset: Int, family: UInt8) -> String {
        if family == UInt8(AF_INET6) {
            // sin6_addr sits at +8: len/family/port(2)/flowinfo(4).
            let at = offset + 8
            guard at + 16 <= buf.count else { return "?" }
            var bytes = Array(buf[at..<(at + 16)])
            var out = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            inet_ntop(AF_INET6, &bytes, &out, socklen_t(out.count))
            var text = String(cString: out)
            if let pct = text.firstIndex(of: "%") {
                text = String(text[text.startIndex..<pct])
            }
            return text
        }
        if family == UInt8(AF_INET) {
            // sin_addr sits at +4: len/family/port(2).
            let at = offset + 4
            guard at + 4 <= buf.count else { return "?" }
            var bytes = Array(buf[at..<(at + 4)])
            var out = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &bytes, &out, socklen_t(out.count))
            return String(cString: out)
        }
        if family == UInt8(AF_LINK) {
            return "link"
        }
        return "fam\(family)"
    }

    // Netmask sockaddrs frequently carry family 0 and a short length, so the
    // prefix is counted from the raw bytes rather than parsed as an address.
    private static func maskPrefix(buf: [UInt8], offset: Int, saLen: Int) -> Int? {
        let start = offset + 2
        let stop = min(offset + saLen, buf.count)
        guard start < stop else { return 0 }
        var bits = 0
        for i in start..<stop {
            bits += buf[i].nonzeroBitCount
        }
        return bits
    }

    private static func routeFlagText(_ flags: Int32) -> String {
        var out: [String] = []
        // Values from <net/route.h>, restated because the header is not exposed.
        if flags & 0x1 != 0 { out.append("UP") }
        if flags & 0x2 != 0 { out.append("GW") }
        if flags & 0x4 != 0 { out.append("HOST") }
        if flags & 0x8 != 0 { out.append("REJECT") }
        if flags & 0x1000 != 0 { out.append("BLACKHOLE") }
        if flags & 0x1000000 != 0 { out.append("IFSCOPE") }
        return out.isEmpty ? "-" : out.joined(separator: "+")
    }

    private static func interfaceName(index: Int) -> String {
        guard index > 0 else { return "?" }
        var buf = [CChar](repeating: 0, count: Int(IFNAMSIZ) + 1)
        guard if_indextoname(UInt32(index), &buf) != nil else {
            return "idx\(index)"
        }
        return String(cString: buf)
    }

    // Does the stack believe it can reach a global IPv6 address right now?
    // This is the programmatic equivalent of the Safari step in the test plan.
    private static func reachabilitySummary() -> String {
        let target = "2606:4700:4700::1111"
        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = UInt8(AF_INET6)
        addr.sin6_port = UInt16(443).bigEndian
        guard target.withCString({ inet_pton(AF_INET6, $0, &addr.sin6_addr) }) == 1 else {
            return "inet_pton failed"
        }

        let fd = socket(AF_INET6, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else {
            return "socket errno=\(errno) (\(String(cString: strerror(errno))))"
        }
        defer { close(fd) }

        var flags = fcntl(fd, F_GETFL, 0)
        flags |= O_NONBLOCK
        _ = fcntl(fd, F_SETFL, flags)

        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        if rc == 0 {
            return "connect(\(target):443) immediate-ok"
        }
        let err = errno
        if err == EINPROGRESS {
            // Give it a moment: a blackholed route fails instantly with
            // EHOSTUNREACH/ENETUNREACH, while a working path stays pending.
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let pollRc = poll(&pfd, 1, 1500)
            if pollRc > 0 {
                var soErr: Int32 = 0
                var len = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len)
                if soErr == 0 {
                    return "connect(\(target):443) connected"
                }
                return "connect(\(target):443) failed soerr=\(soErr) (\(String(cString: strerror(soErr))))"
            }
            if pollRc == 0 {
                return "connect(\(target):443) timeout-1.5s (no answer, path may be blackholed)"
            }
            return "connect(\(target):443) poll errno=\(errno)"
        }
        return "connect(\(target):443) errno=\(err) (\(String(cString: strerror(err))))"
    }
}

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
            AppLogger.shared.log("setRoutes: containsDefault=\(containsDefault) (was \(self.containsDefaultRoute)) v4Count=\(v4Routes.count) v6Count=\(v6Routes.count)")
            self.needFallbackNS = containsDefault
            self.containsDefaultRoute = containsDefault
            self.ipv4Routes = v4Routes
            self.ipv6Routes = v6Routes
            self.updateTunnel(trigger: "setRoutes")
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
        AppLogger.shared.log("setDNS: server=\(config.serverIP) searchDomains=\(dnsSettings.searchDomains ?? [])")
        self.updateTunnel(trigger: "setDNS")
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
    
    private func updateTunnel(trigger: String = "unknown") {
        AppLogger.shared.log("updateTunnel[\(trigger)]: interfaceIP=\(interfaceIP ?? "nil") interfaceIPv6=\(interfaceIPv6 ?? "nil") containsDefaultRoute=\(containsDefaultRoute) v4RouteCount=\(ipv4Routes?.count ?? -1) v6RouteCount=\(ipv6Routes?.count ?? -1) clearMode=\(IPv6ClearMode.active.rawValue)")
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
