import AppIntents
import NetworkExtension
import WidgetKit

@available(iOS 16.0, *)
struct DisconnectVPNIntent: AppIntent {
    static var title: LocalizedStringResource = "Disconnect NetBird VPN"
    static var description: IntentDescription = "Disconnect from the NetBird VPN network."
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let manager = try await VPNIntentHelpers.loadManager() else {
            WidgetCenter.shared.reloadAllTimelines()
            return .result(dialog: "NetBird VPN is not configured.")
        }

        let status = manager.connection.status
        guard status == .connected || status == .connecting else {
            return .result(dialog: "NetBird VPN is already disconnected.")
        }

        VPNIntentHelpers.defaults?.set(WidgetVPNStatus.disconnecting.rawValue, forKey: WidgetConstants.keyVPNStatus)
        WidgetCenter.shared.reloadAllTimelines()

        manager.connection.stopVPNTunnel()

        let final = await VPNIntentHelpers.waitForStableState(manager: manager)
        if final == .disconnected {
            return .result(dialog: "NetBird VPN disconnected.")
        } else {
            return .result(dialog: "NetBird VPN failed to disconnect.")
        }
    }
}
