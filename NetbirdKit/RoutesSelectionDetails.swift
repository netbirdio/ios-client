struct RoutesSelectionDetails: Codable {
    var all: Bool
    var append: Bool
    var routeSelectionInfo: [RoutesSelectionInfo]
}

struct RoutesSelectionInfo: Codable, Identifiable {
    var id: UUID
    var name: String
    var network: String
    var selected: Bool

    init(id: UUID = UUID(), name: String, network: String, selected: Bool) {
        self.id = id
        self.name = name
        self.network = network
        self.selected = selected
    }

    // Codable conformance with custom keys
    enum CodingKeys: String, CodingKey {
        case id, name, network, selected
    }
}
