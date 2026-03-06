//
//  WiFiOnDemandPolicy.swift
//  NetBird
//

enum WiFiOnDemandPolicy: String, CaseIterable {
    case always
    case onlyOn
    case exceptOn
    case never
    case doNothing

    var displayName: String {
        switch self {
        case .always: return "Always"
        case .onlyOn: return "Only On"
        case .exceptOn: return "Except On"
        case .never: return "Never"
        case .doNothing: return "Do Nothing"
        }
    }
}
