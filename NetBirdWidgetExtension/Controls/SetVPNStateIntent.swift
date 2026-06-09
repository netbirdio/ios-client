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

        // Write the transitioning state immediately before the async loadManager call
        // so the Control Center updates without waiting for loadAllFromPreferences.
        let transitioning: WidgetVPNStatus = value ? .connecting : .disconnecting
        defaults?.set(transitioning.rawValue, forKey: WidgetConstants.keyVPNStatus)
        WidgetCenter.shared.reloadAllTimelines()

        guard let manager = await loadManager() else {
            defaults?.set(WidgetVPNStatus.disconnected.rawValue, forKey: WidgetConstants.keyVPNStatus)
            WidgetCenter.shared.reloadAllTimelines()
            await reload()
            return .result()
        }

        if value {
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
