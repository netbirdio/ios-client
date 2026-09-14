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
            let nextUpdate: Date
            if entry.neWasTransitioning {
                // NE was mid-transition; poll frequently so the widget recovers
                // to the correct stable state as soon as NE settles.
                nextUpdate = entry.date.addingTimeInterval(WidgetConstants.transitionPollInterval)
            } else {
                nextUpdate = Calendar.current.date(
                    byAdding: .minute,
                    value: WidgetConstants.timelineRefreshMinutes,
                    to: entry.date
                ) ?? entry.date.addingTimeInterval(300)
            }
            completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
        }
    }

    private func loadEntry(completion: @escaping (VPNStatusEntry) -> Void) {
        let defaults = UserDefaults(suiteName: WidgetConstants.appGroupSuite)
        let ip = defaults?.string(forKey: WidgetConstants.keyIP) ?? ""
        let fqdn = defaults?.string(forKey: WidgetConstants.keyFQDN) ?? ""
        let loginRequired = defaults?.bool(forKey: WidgetConstants.keyLoginRequired) ?? false
        let configPathStored = defaults?.string(forKey: WidgetConstants.keyActiveConfigPath) != nil

        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            let manager = (error == nil) ? managers?.first : nil
            let status: WidgetVPNStatus
            var effectiveLoginRequired = loginRequired
            var neWasTransitioning = false

            if let manager = manager {
                let neStatus = WidgetVPNStatus(neStatus: manager.connection.status)
                if neStatus.isStable {
                    status = neStatus
                    defaults?.set(neStatus.rawValue, forKey: WidgetConstants.keyVPNStatus)
                } else {
                    // NE is mid-transition; show the last known stable state so the
                    // widget never displays a permanent spinner.
                    let persistedRaw = defaults?.string(forKey: WidgetConstants.keyVPNStatus) ?? "disconnected"
                    let persisted = WidgetVPNStatus(rawValue: persistedRaw) ?? .disconnected
                    status = persisted.isStable ? persisted : .disconnected
                    neWasTransitioning = true
                }
                if neStatus == .connected && loginRequired {
                    defaults?.set(false, forKey: WidgetConstants.keyLoginRequired)
                    effectiveLoginRequired = false
                }
            } else {
                // No NE manager — fall back to last persisted stable state.
                let persistedRaw = defaults?.string(forKey: WidgetConstants.keyVPNStatus) ?? "disconnected"
                let persisted = WidgetVPNStatus(rawValue: persistedRaw) ?? .disconnected
                status = persisted.isStable ? persisted : .disconnected
            }

            completion(VPNStatusEntry(
                date: Date(),
                status: status,
                ip: ip,
                fqdn: fqdn,
                needsAppSetup: manager == nil || !configPathStored || effectiveLoginRequired,
                loginRequired: effectiveLoginRequired,
                neWasTransitioning: neWasTransitioning
            ))
        }
    }
}
