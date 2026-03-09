//
//  CellularOnDemandPolicy.swift
//  NetBird
//

enum CellularOnDemandPolicy: String, CaseIterable {
    case always
    case never
    case doNothing

    var displayName: String {
        switch self {
        case .always: return "Always"
        case .never: return "Never"
        case .doNothing: return "Do Nothing"
        }
    }
}
