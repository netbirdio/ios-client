import Foundation

enum WidgetConstants {
    static let appGroupSuite = "group.io.netbird.app"
    static let deepLinkConnect = URL(string: "netbird://connect")
    static let deepLinkDisconnect = URL(string: "netbird://disconnect")
    static let deepLinkLogin = URL(string: "netbird://login")

    // UserDefaults keys (must match GlobalConstants in NetbirdKit)
    static let keyVPNStatus = "netbird.widget.vpnStatus"
    static let keyIP = "netbird.widget.ip"
    static let keyFQDN = "netbird.widget.fqdn"
    static let keyLoginRequired = "netbird.loginRequired"

    static let pollInterval: TimeInterval = 0.3
    static let pollTimeout: TimeInterval = 5.0
    static let timelineRefreshMinutes = 5

    static let keyTransitionStartTime = "netbird.widget.transitionStartTime"
    static let transitionPollInterval: TimeInterval = 2.0
    // How long to prefer the persisted transitioning state over NE snap-back.
    // After this window, NE status is always the source of truth.
    static let snapbackWindow: TimeInterval = 3.0
}
