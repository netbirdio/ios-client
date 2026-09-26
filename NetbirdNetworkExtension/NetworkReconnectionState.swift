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
}

/// Deduplicates OS notifications without suppressing changes during reconnection.
/// All access is serialized on the provider's monitorQueue; retry/debounce policy
/// belongs to the Go core's network event manager.
struct NetworkReconnectionState {
    struct Change {
        let networkChanged: Bool
    }

    let sessionID = UUID()
    private(set) var isActive = true
    private var hasConnected = false
    private(set) var isReasserting = false
    private var hasInitialPath = false
    private var network: UnderlyingNetwork?

    mutating func update(_ next: UnderlyingNetwork?, forceRefresh: Bool = false) -> Change? {
        guard isActive, forceRefresh || !hasInitialPath || network != next else { return nil }
        // The first satisfied path establishes a baseline. Returning from an
        // observed outage must refresh connections even on the same interface/SIM.
        let changed = (forceRefresh || hasInitialPath) && next != nil
        hasInitialPath = true
        network = next
        return Change(networkChanged: changed)
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

    mutating func connectionChanged(_ state: ClientState) {
        guard isActive else { return }
        if state == .connected { hasConnected = true }
        // Initial startup and terminal disconnection are not reassertion.
        isReasserting = hasConnected && state == .connecting
    }

    mutating func stop() {
        isActive = false
        isReasserting = false
    }
}
