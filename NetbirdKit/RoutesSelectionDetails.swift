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
    // Connection status computed by the core ("Connected"/"Idle"), so the UI need
    // not infer it from the (possibly comma-joined) network string. May be empty
    // for older cores; callers fall back to the legacy network-matching logic then.
    var status: String?

    init(id: UUID = UUID(), name: String, network: String?, domains: [DomainDetails]?, selected: Bool, status: String? = nil) {
        self.id = id
        self.name = name
        self.network = network
        self.selected = selected
        self.domains = domains
        self.status = status
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
