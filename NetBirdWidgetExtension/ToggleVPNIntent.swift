import AppIntents
import NetworkExtension
import WidgetKit

@available(iOS 16.0, *)
struct ToggleVPNIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle VPN"
    static var description: IntentDescription = "Connect or disconnect the NetBird VPN."
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Action")
    var action: String

    init() {
        self.action = "connect"
    }

    init(action: String) {
        self.action = action
    }

    func perform() async throws -> some IntentResult {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        guard let manager = managers.first else {
            WidgetCenter.shared.reloadAllTimelines()
            return .result()
        }

        let defaults = UserDefaults(suiteName: WidgetConstants.appGroupSuite)

        if action == "connect" {
            try connectIfNeeded(manager: manager, defaults: defaults)
        } else {
            disconnectIfNeeded(manager: manager, defaults: defaults)
        }

        await waitForStableState(manager: manager, defaults: defaults)

        return .result()
    }

    private func connectIfNeeded(manager: NETunnelProviderManager, defaults: UserDefaults?) throws {
        let status = manager.connection.status
        guard status == .disconnected || status == .invalid else { return }

        defaults?.set(WidgetVPNStatus.connecting.rawValue, forKey: WidgetConstants.keyVPNStatus)
        WidgetCenter.shared.reloadAllTimelines()

        let session = manager.connection as? NETunnelProviderSession
        try session?.startVPNTunnel()
    }

    private func disconnectIfNeeded(manager: NETunnelProviderManager, defaults: UserDefaults?) {
        let status = manager.connection.status
        guard status == .connected || status == .connecting else { return }

        defaults?.set(WidgetVPNStatus.disconnecting.rawValue, forKey: WidgetConstants.keyVPNStatus)
        WidgetCenter.shared.reloadAllTimelines()

        manager.connection.stopVPNTunnel()
    }

    private func waitForStableState(manager: NETunnelProviderManager, defaults: UserDefaults?) async {
        let deadline = Date().addingTimeInterval(WidgetConstants.pollTimeout)

        while Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(WidgetConstants.pollInterval * 1_000_000_000))

            let current = WidgetVPNStatus(neStatus: manager.connection.status)
            if current.isStable {
                break
            }
        }

        let finalStatus = WidgetVPNStatus(neStatus: manager.connection.status)
        defaults?.set(finalStatus.rawValue, forKey: WidgetConstants.keyVPNStatus)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
