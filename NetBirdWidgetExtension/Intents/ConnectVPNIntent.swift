import AppIntents
import NetworkExtension
import WidgetKit

@available(iOS 16.0, *)
struct ConnectVPNIntent: AppIntent {
    static var title: LocalizedStringResource = "Connect NetBird VPN"
    static var description: IntentDescription = "Connect to the NetBird VPN network."
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let manager = try await VPNIntentHelpers.loadManager() else {
            WidgetCenter.shared.reloadAllTimelines()
            return .result(dialog: "NetBird VPN is not configured.")
        }

        guard !VPNIntentHelpers.isLoginRequired else {
            WidgetCenter.shared.reloadAllTimelines()
            return .result(dialog: "NetBird requires sign-in. Please open the app.")
        }

        let status = manager.connection.status
        guard status == .disconnected || status == .invalid else {
            return .result(dialog: "NetBird VPN is already \(WidgetVPNStatus(neStatus: status).displayText.lowercased()).")
        }

        VPNIntentHelpers.defaults?.set(WidgetVPNStatus.connecting.rawValue, forKey: WidgetConstants.keyVPNStatus)
        WidgetCenter.shared.reloadAllTimelines()

        let session = manager.connection as? NETunnelProviderSession
        try session?.startVPNTunnel()

        let final = await VPNIntentHelpers.waitForStableState(manager: manager)
        if final == .connected {
            return .result(dialog: "NetBird VPN connected.")
        } else if VPNIntentHelpers.isLoginRequired {
            return .result(dialog: "NetBird requires sign-in. Please open the app.")
        } else {
            return .result(dialog: "NetBird VPN failed to connect.")
        }
    }
}
