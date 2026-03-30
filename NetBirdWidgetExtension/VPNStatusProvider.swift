import WidgetKit
import NetworkExtension

struct VPNStatusProvider: TimelineProvider {

    func placeholder(in context: Context) -> VPNStatusEntry {
        VPNStatusEntry(
            date: Date(),
            status: .disconnected,
            ip: "100.x.x.x",
            fqdn: "device.netbird.cloud",
            needsAppSetup: false,
            loginRequired: false
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (VPNStatusEntry) -> Void) {
        loadEntry(completion: completion)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<VPNStatusEntry>) -> Void) {
        loadEntry { entry in
            let nextUpdate = Calendar.current.date(
                byAdding: .minute,
                value: WidgetConstants.timelineRefreshMinutes,
                to: entry.date
            ) ?? entry.date.addingTimeInterval(300)

            completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
        }
    }

    private func loadEntry(completion: @escaping (VPNStatusEntry) -> Void) {
        let defaults = UserDefaults(suiteName: WidgetConstants.appGroupSuite)
        let ip = defaults?.string(forKey: WidgetConstants.keyIP) ?? ""
        let fqdn = defaults?.string(forKey: WidgetConstants.keyFQDN) ?? ""
        let loginRequired = defaults?.bool(forKey: WidgetConstants.keyLoginRequired) ?? false

        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            let manager = (error == nil) ? managers?.first : nil
            let status: WidgetVPNStatus

            if let manager {
                status = WidgetVPNStatus(neStatus: manager.connection.status)
            } else {
                let raw = defaults?.string(forKey: WidgetConstants.keyVPNStatus) ?? "disconnected"
                status = WidgetVPNStatus(rawValue: raw) ?? .disconnected
            }

            let entry = VPNStatusEntry(
                date: Date(),
                status: status,
                ip: ip,
                fqdn: fqdn,
                needsAppSetup: manager == nil || loginRequired,
                loginRequired: loginRequired
            )
            completion(entry)
        }
    }
}
