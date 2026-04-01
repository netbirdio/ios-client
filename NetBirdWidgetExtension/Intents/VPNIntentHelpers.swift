import AppIntents
import NetworkExtension
import WidgetKit

/// Shared helpers used across all VPN intents.
@available(iOS 16.0, *)
enum VPNIntentHelpers {

    static func loadManager() async throws -> NETunnelProviderManager? {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        return managers.first
    }

    static var defaults: UserDefaults? {
        UserDefaults(suiteName: WidgetConstants.appGroupSuite)
    }

    static var isLoginRequired: Bool {
        defaults?.bool(forKey: WidgetConstants.keyLoginRequired) ?? false
    }

    @discardableResult
    static func waitForStableState(manager: NETunnelProviderManager) async -> WidgetVPNStatus {
        let deadline = Date().addingTimeInterval(WidgetConstants.pollTimeout)

        while Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(WidgetConstants.pollInterval * 1_000_000_000))

            if isLoginRequired {
                WidgetCenter.shared.reloadAllTimelines()
                return WidgetVPNStatus(neStatus: manager.connection.status)
            }

            if WidgetVPNStatus(neStatus: manager.connection.status).isStable { break }
        }

        let final = WidgetVPNStatus(neStatus: manager.connection.status)
        defaults?.set(final.rawValue, forKey: WidgetConstants.keyVPNStatus)
        WidgetCenter.shared.reloadAllTimelines()
        return final
    }
}
