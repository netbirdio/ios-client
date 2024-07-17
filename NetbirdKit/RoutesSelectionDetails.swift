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

    init(id: UUID = UUID(), name: String, network: String?, domains: [DomainDetails]?, selected: Bool) {
        self.id = id
        self.name = name
        self.network = network
        self.selected = selected
        self.domains = domains
    }

    // Codable conformance with custom keys
    enum CodingKeys: String, CodingKey {
        case id, name, network, domains, selected
    }
}

extension RoutesSelectionInfo: Equatable {
    static func == (lhs: RoutesSelectionInfo, rhs: RoutesSelectionInfo) -> Bool {
        return lhs.id == rhs.id &&
        lhs.name == rhs.name &&
        lhs.network == rhs.network &&
        lhs.domains == rhs.domains &&
        lhs.selected == rhs.selected
    }
}

struct DomainDetails: Codable, Hashable {
    let domain: String
    let resolvedips: String?
}

extension DomainDetails: Equatable {
    static func == (lhs: DomainDetails, rhs: DomainDetails) -> Bool {
        return lhs.domain == rhs.domain &&
        lhs.resolvedips == rhs.resolvedips
    }
}
