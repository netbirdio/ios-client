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
            if entry.status.isTransitioning {
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

        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            let manager = (error == nil) ? managers?.first : nil
            let status: WidgetVPNStatus

            let persistedRaw = defaults?.string(forKey: WidgetConstants.keyVPNStatus) ?? "disconnected"
            let persisted = WidgetVPNStatus(rawValue: persistedRaw) ?? .disconnected

            if let manager {
                let neStatus = WidgetVPNStatus(neStatus: manager.connection.status)

                // Use the persisted transitioning state only within the snap-back window —
                // the brief period right after a tap when NE still reports the old stable state.
                // Outside this window NE is always the source of truth, preventing stuck states.
                let startTime = defaults?.double(forKey: WidgetConstants.keyTransitionStartTime) ?? 0
                let inSnapbackWindow = Date().timeIntervalSince1970 - startTime < WidgetConstants.snapbackWindow
                let usePersistedTransition = inSnapbackWindow &&
                    persisted.isTransitioning && neStatus.isStable &&
                    !(persisted == .connecting && neStatus == .connected) &&
                    !(persisted == .disconnecting && neStatus == .disconnected)

                status = usePersistedTransition ? persisted : neStatus

                // Keep the persisted key in sync with the resolved stable state.
                if !usePersistedTransition && persisted.isTransitioning {
                    defaults?.set(neStatus.rawValue, forKey: WidgetConstants.keyVPNStatus)
                }
            } else {
                status = persisted
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
