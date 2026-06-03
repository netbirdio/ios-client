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
    // Active profile paths written by the main app so the widget intent can pass
    // them to startVPNTunnel(options:) without the main app being in-process.
    static let keyActiveConfigPath = "netbird.widget.activeConfigPath"
    static let keyActiveStatePath  = "netbird.widget.activeStatePath"

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
    // old stable state. Equals transitionMaxDuration so we never prematurely snap to
    // "Disconnected" just because NE is slow to start after startVPNTunnel().
    static let snapbackWindow: TimeInterval = 20.0
    // Hard upper bound on a transitioning state. A fallback timeline entry is baked
    // in at this offset so the widget never shows "Connecting…"/"Disconnecting…" forever,
    // even when the NE process cannot push reloadAllTimelines() (app closed).
    static let transitionMaxDuration: TimeInterval = 20.0
}
