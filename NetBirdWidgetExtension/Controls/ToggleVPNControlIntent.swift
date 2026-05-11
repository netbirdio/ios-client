import AppIntents
import NetworkExtension
import WidgetKit

@available(iOS 18.0, *)
struct ToggleVPNControlIntent: SetValueIntent {
    static var title: LocalizedStringResource = "Toggle NetBird VPN"
    static var openAppWhenRun: Bool = false

    /// Set to `true` to connect, `false` to disconnect.
    /// The system fills this in before calling `perform()`.
    @Parameter(title: "Connected")
    var value: Bool

    init() { self.value = false }
    init(value: Bool) { self.value = value }

    func perform() async throws -> some IntentResult {
        guard let manager = try await VPNIntentHelpers.loadManager() else {
            await ControlCenter.shared.reloadControls(ofKind: NetBirdVPNControl.kind)
            return .result()
        }

        if value {
            guard !VPNIntentHelpers.isLoginRequired else {
                await ControlCenter.shared.reloadControls(ofKind: NetBirdVPNControl.kind)
                return .result()
            }
            let status = manager.connection.status
            if status == .disconnected || status == .invalid {
                VPNIntentHelpers.defaults?.set(WidgetVPNStatus.connecting.rawValue,
                                               forKey: WidgetConstants.keyVPNStatus)
                WidgetCenter.shared.reloadAllTimelines()
                let session = manager.connection as? NETunnelProviderSession
                try session?.startVPNTunnel()
            }
        } else {
            let status = manager.connection.status
            if status == .connected || status == .connecting {
                VPNIntentHelpers.defaults?.set(WidgetVPNStatus.disconnecting.rawValue,
                                               forKey: WidgetConstants.keyVPNStatus)
                WidgetCenter.shared.reloadAllTimelines()
                manager.connection.stopVPNTunnel()
            }
        }

        await VPNIntentHelpers.waitForStableState(manager: manager)
        await ControlCenter.shared.reloadControls(ofKind: NetBirdVPNControl.kind)
        return .result()
    }
}
