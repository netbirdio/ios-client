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
        self.addresses = addresses.sorted()
        self.gateways = gateways.sorted()
        self.supportsIPv4 = supportsIPv4
        self.supportsIPv6 = supportsIPv6
        self.dataServiceIdentifier = dataServiceIdentifier
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
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, socklen_t(address.pointee.sa_len), &host,
                               socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    addresses.append("\(String(cString: entry.pointee.ifa_name)):\(String(cString: host))")
                }
            }
        }
        self.addresses = addresses.sorted()
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
