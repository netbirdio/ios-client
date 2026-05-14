import AppIntents
import NetworkExtension
import WidgetKit

/// Used by the widget buttons. For Siri/Shortcuts use ConnectVPNIntent or DisconnectVPNIntent.
@available(iOS 16.0, *)
struct ToggleVPNIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle NetBird VPN"
    static var description: IntentDescription = "Connect or disconnect the NetBird VPN."
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Action")
    var action: String

    init() { self.action = "connect" }
    init(action: String) { self.action = action }

    func perform() async throws -> some IntentResult {
        guard let manager = try await VPNIntentHelpers.loadManager() else {
            WidgetCenter.shared.reloadAllTimelines()
            return .result()
        }

        let defaults = VPNIntentHelpers.defaults

        if action == "connect" {
            guard !VPNIntentHelpers.isLoginRequired else {
                WidgetCenter.shared.reloadAllTimelines()
                return .result()
            }
            let status = manager.connection.status
            if status == .disconnected || status == .invalid {
                defaults?.set(WidgetVPNStatus.connecting.rawValue, forKey: WidgetConstants.keyVPNStatus)
                defaults?.set(Date().timeIntervalSince1970, forKey: WidgetConstants.keyTransitionStartTime)
                let session = manager.connection as? NETunnelProviderSession
                try session?.startVPNTunnel()
            }
        } else {
            let status = manager.connection.status
            if status == .connected || status == .connecting {
                defaults?.set(WidgetVPNStatus.disconnecting.rawValue, forKey: WidgetConstants.keyVPNStatus)
                defaults?.set(Date().timeIntervalSince1970, forKey: WidgetConstants.keyTransitionStartTime)
                manager.connection.stopVPNTunnel()
            }
        }

        // Return immediately so the widget re-renders the transitioning state right away.
        // VPNStatusProvider polls every 2 s while transitioning and clears the state once NE stabilises.
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
