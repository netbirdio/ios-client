import AppIntents
import NetworkExtension
import WidgetKit

@available(iOS 18.0, *)
struct SetVPNStateIntent: SetValueIntent {
    static var title: LocalizedStringResource = "Set NetBird VPN State"
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Connect")
    var value: Bool

    func perform() async throws -> some IntentResult {
        let defaults = VPNIntentHelpers.defaults
        let loginRequired = defaults?.bool(forKey: WidgetConstants.keyLoginRequired) ?? false

        guard !loginRequired else {
            await reload()
            return .result()
        }

        guard let manager = await loadManager() else {
            await reload()
            return .result()
        }

        if value {
            defaults?.set(WidgetVPNStatus.connecting.rawValue, forKey: WidgetConstants.keyVPNStatus)
            WidgetCenter.shared.reloadAllTimelines()
            guard let session = manager.connection as? NETunnelProviderSession else {
                defaults?.set(WidgetVPNStatus.disconnected.rawValue, forKey: WidgetConstants.keyVPNStatus)
                WidgetCenter.shared.reloadAllTimelines()
                await reload()
                return .result()
            }
            do {
                try session.startVPNTunnel()
            } catch {
                defaults?.set(WidgetVPNStatus.disconnected.rawValue, forKey: WidgetConstants.keyVPNStatus)
                WidgetCenter.shared.reloadAllTimelines()
            }
        } else {
            defaults?.set(WidgetVPNStatus.disconnecting.rawValue, forKey: WidgetConstants.keyVPNStatus)
            WidgetCenter.shared.reloadAllTimelines()
            manager.connection.stopVPNTunnel()
        }

        await reload()
        return .result()
    }

    private func loadManager() async -> NETunnelProviderManager? {
        await withCheckedContinuation { continuation in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                continuation.resume(returning: managers?.first)
            }
        }
    }

    private func reload() async {
        await ControlCenter.shared.reloadControls(ofKind: NetBirdVPNControl.kind)
    }
}
