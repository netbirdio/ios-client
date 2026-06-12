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
                let session = manager.connection as? NETunnelProviderSession
                var options: [String: NSObject] = [:]
                if let p = defaults?.string(forKey: WidgetConstants.keyActiveConfigPath) {
                    options["configPath"] = p as NSObject
                }
                if let p = defaults?.string(forKey: WidgetConstants.keyActiveStatePath) {
                    options["statePath"] = p as NSObject
                }
                try session?.startVPNTunnel(options: options.isEmpty ? nil : options)
            }
        } else {
            let neStatus = manager.connection.status
            let persistedRaw = defaults?.string(forKey: WidgetConstants.keyVPNStatus) ?? "disconnected"
            let persisted = WidgetVPNStatus(rawValue: persistedRaw) ?? .disconnected
            let shouldDisconnect = neStatus == .connected || neStatus == .connecting
                || persisted == .connected || persisted == .connecting
            if shouldDisconnect {
                manager.connection.stopVPNTunnel()
            }
        }

        await VPNIntentHelpers.waitForStableState(manager: manager)
        return .result()
    }
}
