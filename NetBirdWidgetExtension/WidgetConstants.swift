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
    // Fallback poll interval while the VPN is transitioning.
    // The primary update mechanism is a push from PacketTunnelProvider via
    // WidgetCenter.reloadAllTimelines(). This poll is a safety net only, so keep
    // it conservative to avoid exhausting the ~40-70 daily WidgetKit refresh budget.
    static let transitionPollInterval: TimeInterval = 5.0
    // How long to show the persisted transitioning state while NE still reports the
    // old stable state. 8 s covers the typical delay between startVPNTunnel() and
    // NE first reporting .connecting. After this window NE is always authoritative.
    static let snapbackWindow: TimeInterval = 8.0
    // Hard upper bound on a transitioning state. If the widget is still showing
    // "Connecting…"/"Disconnecting…" after this many seconds, force NE as truth.
    static let transitionMaxDuration: TimeInterval = 60.0
}
