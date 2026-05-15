import AppIntents
import NetworkExtension
import WidgetKit

@available(iOS 18.0, *)
struct VPNControlIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle NetBird VPN"
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        let defaults = VPNIntentHelpers.defaults
        let loginRequired = defaults?.bool(forKey: WidgetConstants.keyLoginRequired) ?? false

        guard !loginRequired else {
            await reload()
            return .result()
        }

        guard let first = await loadManager() else {
            await reload()
            return .result()
        }

        let status = first.connection.status

        switch status {
        case .disconnected, .invalid:
            defaults?.set(WidgetVPNStatus.connecting.rawValue, forKey: WidgetConstants.keyVPNStatus)
            WidgetCenter.shared.reloadAllTimelines()
            let session = first.connection as? NETunnelProviderSession
            try? session?.startVPNTunnel()
        case .connected, .connecting:
            defaults?.set(WidgetVPNStatus.disconnecting.rawValue, forKey: WidgetConstants.keyVPNStatus)
            WidgetCenter.shared.reloadAllTimelines()
            first.connection.stopVPNTunnel()
        default:
            break
        }

        await reload()
        return .result()
    }

    private func loadManager() async -> NETunnelProviderManager? {
        await withCheckedContinuation { continuation in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                guard error == nil else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: managers?.first)
            }
        }
    }

    private func reload() async {
        await ControlCenter.shared.reloadControls(ofKind: NetBirdVPNControl.kind)
    }
}
