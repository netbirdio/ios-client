import Foundation
import Network

/// Only physical interfaces participate: installing the VPN's own routes must not
/// trigger another connection refresh. Interface identity catches cellular-to-cellular moves;
/// addresses catch a new network that reuses the same interface.
struct UnderlyingNetwork: Equatable {
    let interfaces: [String]
    let addresses: [String]
    let gateways: [String]
    let supportsIPv4: Bool
    let supportsIPv6: Bool
    let dataServiceIdentifier: String?

    init(interfaces: [String], addresses: [String] = [], gateways: [String] = [], supportsIPv4: Bool = true, supportsIPv6: Bool = true, dataServiceIdentifier: String? = nil) {
        self.interfaces = interfaces.sorted()
        self.addresses = Array(Set(addresses)).sorted()
        self.gateways = gateways.sorted()
        self.supportsIPv4 = supportsIPv4
        self.supportsIPv6 = supportsIPv6
        self.dataServiceIdentifier = dataServiceIdentifier
    }

    /// Uses the interface netmask, rather than assuming every IPv6 link is /64.
    static func ipv6NetworkIdentity(_ address: IPv6Address, netmask: IPv6Address) -> String? {
        let bytes = zip(address.rawValue, netmask.rawValue).map { $0 & $1 }
        guard let prefix = IPv6Address(Data(bytes)) else { return nil }
        let prefixLength = netmask.rawValue.reduce(0) { $0 + $1.nonzeroBitCount }
        return "\(prefix)/\(prefixLength)"
    }

    init(path: NWPath, dataServiceIdentifier: String?) {
        let interfaces = path.availableInterfaces.filter {
            [.wifi, .cellular, .wiredEthernet].contains($0.type) && path.usesInterfaceType($0.type)
        }
        self.interfaces = interfaces.map { "\($0.name):\($0.index)" }.sorted()
        self.gateways = path.gateways.map { String(describing: $0) }.sorted()
        self.supportsIPv4 = path.supportsIPv4
        self.supportsIPv6 = path.supportsIPv6
        self.dataServiceIdentifier = path.usesInterfaceType(.cellular) ? dataServiceIdentifier : nil

        let names = Set(interfaces.map(\.name))
        var addresses: [String] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&head) == 0 {
            defer { freeifaddrs(head) }
            var cursor = head
            while let entry = cursor {
                defer { cursor = entry.pointee.ifa_next }
                guard names.contains(String(cString: entry.pointee.ifa_name)),
                      let address = entry.pointee.ifa_addr,
                      address.pointee.sa_family == AF_INET || address.pointee.sa_family == AF_INET6 else { continue }
                if address.pointee.sa_family == AF_INET6 {
                    // Privacy addresses rotate on the same network. Compare the
                    // advertised prefix instead of reconnecting for each host ID.
                    guard let mask = entry.pointee.ifa_netmask,
                          mask.pointee.sa_family == AF_INET6 else { continue }
                    var ipv6 = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
                    var netmask = UnsafeRawPointer(mask).assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
                    let addressData = withUnsafeBytes(of: &ipv6) { Data($0) }
                    let maskData = withUnsafeBytes(of: &netmask) { Data($0) }
                    guard let ipv6Address = IPv6Address(addressData),
                          let ipv6Mask = IPv6Address(maskData),
                          let prefix = Self.ipv6NetworkIdentity(ipv6Address, netmask: ipv6Mask) else { continue }
                    addresses.append("\(String(cString: entry.pointee.ifa_name)):\(prefix)")
                    continue
                }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, socklen_t(address.pointee.sa_len), &host,
                               socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    addresses.append("\(String(cString: entry.pointee.ifa_name)):\(String(cString: host))")
                }
            }
        }
        self.addresses = Array(Set(addresses)).sorted()
    }

    /// Wi-Fi, wired (en*) and cellular (pdp_ip*) interfaces. The VPN's own utun,
    /// AWDL, hotspot bridges and loopback do not give the device a network.
    static func isPhysicalInterface(_ name: String) -> Bool {
        name.hasPrefix("en") || name.hasPrefix("pdp_ip")
    }

    /// A link-local or loopback address does not reach any server.
    static func isUsableAddress(_ host: String) -> Bool {
        let host = host.split(separator: "%", maxSplits: 1).first.map(String.init) ?? host
        if let ipv4 = IPv4Address(host) {
            return !ipv4.isLinkLocal && !ipv4.isLoopback && ipv4 != .any
        }
        if let ipv6 = IPv6Address(host) {
            return !ipv6.isLinkLocal && !ipv6.isLoopback && ipv6 != .any
        }
        return false
    }

    /// Reads the physical interfaces that are up, running and hold a usable address
    /// straight from the kernel, bypassing the path monitor. Returns nil when there is none.
    /// Only IPv4 addresses enter the identity: IPv6 privacy addresses rotate on the same network.
    static func fromInterfaceAddresses() -> UnderlyingNetwork? {
        var names = Set<String>()
        var addresses: [String] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }
        defer { freeifaddrs(head) }
        let required = UInt32(IFF_UP | IFF_RUNNING)
        var cursor = head
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let name = String(cString: entry.pointee.ifa_name)
            guard isPhysicalInterface(name),
                  entry.pointee.ifa_flags & required == required,
                  let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == AF_INET || address.pointee.sa_family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host,
                              socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            guard isUsableAddress(text) else { continue }
            names.insert(name)
            if address.pointee.sa_family == AF_INET {
                addresses.append("\(name):\(text)")
            }
        }
        return names.isEmpty ? nil : UnderlyingNetwork(interfaces: Array(names), addresses: addresses)
    }
}

/// Deduplicates OS notifications without suppressing changes during reconnection.
/// All access is serialized on the provider's monitorQueue; retry/debounce policy
/// belongs to the Go core's network event manager.
struct NetworkReconnectionState {
    struct Change {
        enum Reason: String {
            case initial, unavailable, recovered, changed
        }
        let reason: Reason
        var networkChanged: Bool { reason == .recovered || reason == .changed }
    }

    let sessionID = UUID()
    private(set) var isActive = true
    private var hasConnected = false
    private var hasInitialPath = false
    private var network: UnderlyingNetwork?
    /// Set once the path monitor reports a usable path in this session.
    private(set) var isPathMonitorTrusted = false

    /// Returns the network to act on, or nil when the device has no network.
    /// An unsatisfied path parks the core, so the report must be right. On some devices
    /// (seen on iOS 15) the extension's monitor reports unsatisfied with no interfaces
    /// for the whole session while Wi-Fi and cellular work. Until the monitor reports a
    /// usable path once, an unsatisfied report is checked against the interfaces.
    mutating func resolveNetwork(pathAllowsConnection: Bool,
                                 fromPath: () -> UnderlyingNetwork,
                                 fromInterfaces: () -> UnderlyingNetwork?) -> UnderlyingNetwork? {
        if pathAllowsConnection {
            isPathMonitorTrusted = true
            return fromPath()
        }
        return isPathMonitorTrusted ? nil : fromInterfaces()
    }

    /// Reasserting makes iOS hold new flows through the tunnel, so it is raised only while
    /// the device has no network. Management, Signal or peer state never raises it.
    var isReasserting: Bool {
        isActive && hasConnected && hasInitialPath && network == nil
    }

    mutating func update(_ next: UnderlyingNetwork?) -> Change? {
        guard isActive, !hasInitialPath || network != next else { return nil }
        // The first satisfied path establishes a baseline. Returning from an
        // observed outage must refresh connections even on the same interface/SIM.
        let reason: Change.Reason
        if !hasInitialPath {
            reason = .initial
        } else if next == nil {
            reason = .unavailable
        } else if network == nil {
            reason = .recovered
        } else {
            reason = .changed
        }
        hasInitialPath = true
        network = next
        return Change(reason: reason)
    }

    static func allowsConnectionAttempts(_ status: Network.NWPath.Status) -> Bool {
        switch status {
        case .satisfied, .requiresConnection:
            // A dial may activate a requiresConnection path; parking retries here
            // would prevent the very operation needed to bring the network up.
            return true
        case .unsatisfied:
            return false
        @unknown default:
            return true
        }
    }

    /// Both connection events and start completions belong to one engine in one tunnel session.
    func acceptsCallback(sessionID: UUID, engineGeneration: UInt64, currentEngineGeneration: UInt64) -> Bool {
        isActive && self.sessionID == sessionID && engineGeneration == currentEngineGeneration
    }

    /// Disconnecting and Disconnected do not clear reasserting. The core sends Disconnecting
    /// from ClientTeardown inside its retry loop, and Disconnected while Management and Signal
    /// are both down. A real shutdown always goes through stop().
    mutating func connectionChanged(_ state: ClientState) {
        guard isActive else { return }
        if state == .connected { hasConnected = true }
    }

    mutating func stop() {
        isActive = false
    }
}
