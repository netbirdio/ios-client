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

        // Determine the expected transitioning state from the current persisted status
        // and write it immediately before the async loadManager call so the Control
        // Center updates without waiting for loadAllFromPreferences to return.
        let currentRaw = defaults?.string(forKey: WidgetConstants.keyVPNStatus) ?? "disconnected"
        let current = WidgetVPNStatus(rawValue: currentRaw) ?? .disconnected
        let optimisticState: WidgetVPNStatus = (current == .connected || current == .connecting)
            ? .disconnecting : .connecting
        defaults?.set(optimisticState.rawValue, forKey: WidgetConstants.keyVPNStatus)
        WidgetCenter.shared.reloadAllTimelines()

        guard let first = await loadManager() else {
            defaults?.set(WidgetVPNStatus.disconnected.rawValue, forKey: WidgetConstants.keyVPNStatus)
            WidgetCenter.shared.reloadAllTimelines()
            await reload()
            return .result()
        }

        let status = first.connection.status

        switch status {
        case .disconnected, .invalid:
            guard let session = first.connection as? NETunnelProviderSession else {
                defaults?.set(WidgetVPNStatus.disconnected.rawValue, forKey: WidgetConstants.keyVPNStatus)
                WidgetCenter.shared.reloadAllTimelines()
                break
            }
            do {
                try session.startVPNTunnel()
            } catch {
                defaults?.set(WidgetVPNStatus.disconnected.rawValue, forKey: WidgetConstants.keyVPNStatus)
                WidgetCenter.shared.reloadAllTimelines()
            }
        case .connected, .connecting:
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
