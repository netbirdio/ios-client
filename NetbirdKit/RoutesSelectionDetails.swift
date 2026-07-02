//
//  RoutesSelectionDetails.swift
//  NetBird
//

import Foundation
import Combine

struct LoginDiagnostics: Codable {
    var isComplete: Bool
    var isExecuting: Bool
    var loginRequired: Bool
    var configExists: Bool
    var stateExists: Bool
    var lastResult: String
    var lastError: String
}

struct DeviceAuthResponse: Codable {
    var url: String
    var userCode: String
}

struct RoutesSelectionDetails: Codable {
    var all: Bool
    var append: Bool
    var routeSelectionInfo: [RoutesSelectionInfo]
}

class RoutesSelectionInfo: ObservableObject, Codable, Identifiable {
    var id: UUID
    var name: String
    var network: String?
    var domains: [DomainDetails]?
    var selected: Bool
    // Connection status computed by the core ("Connected"/"Idle"). UI consumers read
    // it directly (e.g. RouteCard.statusIndicatorColor uses route.status); there is no
    // network-string fallback. A nil/empty value from an older core is treated as
    // not-connected, so a selected route shows the yellow ("unknown") indicator.
    var status: String?

    init(id: UUID = UUID(), name: String, network: String?, domains: [DomainDetails]?, selected: Bool, status: String? = nil) {
        self.id = id
        self.name = name
        self.network = network
        self.selected = selected
        self.domains = domains
        self.status = status
    }

    // A route that covers all traffic (0.0.0.0/0 or ::/0) is an exit node. The core
    // may merge a v4+v6 pair into a single comma-joined range string.
    var isExitNode: Bool {
        guard let network else { return false }
        return network.split(separator: ",").contains { part in
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            return trimmed == "0.0.0.0/0" || trimmed == "::/0"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, network, domains, selected, status
    }
}

extension RoutesSelectionInfo: Equatable {
    static func == (lhs: RoutesSelectionInfo, rhs: RoutesSelectionInfo) -> Bool {
        return lhs.id == rhs.id &&
        lhs.name == rhs.name &&
        lhs.network == rhs.network &&
        lhs.domains == rhs.domains &&
        lhs.selected == rhs.selected &&
        lhs.status == rhs.status
    }
}

struct DomainDetails: Codable, Hashable {
    let domain: String
    let resolvedIPs: [String]
}

extension DomainDetails: Equatable {
    static func == (lhs: DomainDetails, rhs: DomainDetails) -> Bool {
        return lhs.domain == rhs.domain &&
        lhs.resolvedIPs == rhs.resolvedIPs
    }
}
