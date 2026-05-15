import WidgetKit
import NetworkExtension

struct VPNControlState: Equatable, Sendable {
    let isConfigured: Bool
    let isActive: Bool
}

@available(iOS 18.0, *)
struct VPNControlProvider: ControlValueProvider {

    var previewValue: VPNControlState {
        VPNControlState(isConfigured: true, isActive: false)
    }

    func currentValue() async throws -> VPNControlState {
        let defaults = UserDefaults(suiteName: WidgetConstants.appGroupSuite)
        let loginRequired = defaults?.bool(forKey: WidgetConstants.keyLoginRequired) ?? false
        let persistedRaw = defaults?.string(forKey: WidgetConstants.keyVPNStatus) ?? ""
        let persisted = WidgetVPNStatus(rawValue: persistedRaw)

        // No persisted status means app hasn't configured VPN yet
        guard persisted != nil, !loginRequired else {
            return VPNControlState(isConfigured: false, isActive: false)
        }

        // Try to get live status from NE; fall back to persisted value
        let neStatus = await loadNEStatus()
        let isActive: Bool
        if let live = neStatus {
            isActive = live == .connected || live == .connecting
        } else {
            isActive = persisted == .connected || persisted == .connecting
        }

        return VPNControlState(isConfigured: true, isActive: isActive)
    }

    private func loadNEStatus() async -> WidgetVPNStatus? {
        await withCheckedContinuation { continuation in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                guard error == nil, let manager = managers?.first else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: WidgetVPNStatus(neStatus: manager.connection.status))
            }
        }
    }
}
