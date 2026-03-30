import Foundation

enum WidgetConstants {
    static let appGroupSuite = "group.io.netbird.app"
    static let deepLinkConnect = URL(string: "netbird://connect")
    static let deepLinkLogin = URL(string: "netbird://login")

    // UserDefaults keys (must match GlobalConstants in NetbirdKit)
    static let keyVPNStatus = "netbird.widget.vpnStatus"
    static let keyIP = "netbird.widget.ip"
    static let keyFQDN = "netbird.widget.fqdn"
    static let keyLoginRequired = "netbird.loginRequired"

    static let pollInterval: TimeInterval = 0.3
    static let pollTimeout: TimeInterval = 5.0
    static let timelineRefreshMinutes = 5
}
