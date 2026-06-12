import SwiftUI
import NetworkExtension
import WidgetKit

extension Color {
    // NetBird brand orange (#F68330) — matches the app's AccentColor asset.
    static let netbirdOrange = Color(red: 0.965, green: 0.514, blue: 0.188)
}

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
        case .connecting, .disconnecting: return .netbirdOrange
        case .disconnected: return Color(.systemGray3)
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
    let loginRequired: Bool

    var isConnected: Bool { status == .connected }

    /// Deep-link URL for the pre-iOS 17 `Link` fallback.
    /// Mirrors the routing logic in `WidgetActionButton` so both paths stay in sync.
    /// Returns `nil` when a transitioning state makes any tap meaningless.
    var fallbackDeepLink: URL? {
        guard !status.isTransitioning else { return nil }
        if needsAppSetup && !isConnected {
            return loginRequired ? WidgetConstants.deepLinkLogin : WidgetConstants.deepLinkConnect
        }
        return isConnected ? WidgetConstants.deepLinkDisconnect : WidgetConstants.deepLinkConnect
    }
}
