import SwiftUI
import NetworkExtension
import WidgetKit

enum WidgetVPNStatus: String {
    case connected
    case connecting
    case disconnecting
    case disconnected

    var displayText: String {
        switch self {
        case .connected: return "Connected"
        case .connecting: return "Connecting..."
        case .disconnecting: return "Disconnecting..."
        case .disconnected: return "Disconnected"
        }
    }

    var isTransitioning: Bool {
        self == .connecting || self == .disconnecting
    }

    var isStable: Bool {
        !isTransitioning
    }

    var statusColor: Color {
        switch self {
        case .connected: return .green
        case .connecting, .disconnecting: return .orange
        case .disconnected: return .gray
        }
    }

    init(neStatus: NEVPNStatus) {
        switch neStatus {
        case .connected: self = .connected
        case .connecting, .reasserting: self = .connecting
        case .disconnecting: self = .disconnecting
        case .disconnected, .invalid: self = .disconnected
        @unknown default: self = .disconnected
        }
    }
}

struct VPNStatusEntry: TimelineEntry {
    let date: Date
    let status: WidgetVPNStatus
    let ip: String
    let fqdn: String
    let needsAppSetup: Bool

    var isConnected: Bool { status == .connected }
}
