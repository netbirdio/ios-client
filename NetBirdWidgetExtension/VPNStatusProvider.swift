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
            if entry.status.isTransitioning {
                let pollDate = entry.date.addingTimeInterval(WidgetConstants.transitionPollInterval)

                // Bake in a hard-deadline fallback entry so the widget exits the
                // transitioning state even when reloadAllTimelines() from the NE
                // process is suppressed (app closed). The fallback shows "Disconnected"
                // — the safest assumption for both connect and disconnect transitions.
                // If the real outcome differs, the next getTimeline call (via .after
                // policy or an NE push when the app opens) will correct it.
                let defaults = UserDefaults(suiteName: WidgetConstants.appGroupSuite)
                let startTime = defaults?.double(forKey: WidgetConstants.keyTransitionStartTime) ?? 0
                let deadlineBase = startTime > 0
                    ? Date(timeIntervalSince1970: startTime)
                    : entry.date
                let deadline = deadlineBase.addingTimeInterval(WidgetConstants.transitionMaxDuration)

                if deadline > pollDate {
                    let fallback = VPNStatusEntry(
                        date: deadline,
                        status: .disconnected,
                        ip: entry.ip,
                        fqdn: entry.fqdn,
                        needsAppSetup: entry.needsAppSetup,
                        loginRequired: entry.loginRequired
                    )
                    completion(Timeline(entries: [entry, fallback], policy: .after(pollDate)))
                } else {
                    completion(Timeline(entries: [entry], policy: .after(pollDate)))
                }
            } else {
                let nextUpdate = Calendar.current.date(
                    byAdding: .minute,
                    value: WidgetConstants.timelineRefreshMinutes,
                    to: entry.date
                ) ?? entry.date.addingTimeInterval(300)
                completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
            }
        }
    }

    private func loadEntry(completion: @escaping (VPNStatusEntry) -> Void) {
        let defaults = UserDefaults(suiteName: WidgetConstants.appGroupSuite)
        let ip = defaults?.string(forKey: WidgetConstants.keyIP) ?? ""
        let fqdn = defaults?.string(forKey: WidgetConstants.keyFQDN) ?? ""
        let loginRequired = defaults?.bool(forKey: WidgetConstants.keyLoginRequired) ?? false
        // true when the main app has stored active profile paths (set on every successful connect).
        // If missing, the intent cannot start the tunnel without paths → show "open app" link instead.
        let configPathStored = defaults?.string(forKey: WidgetConstants.keyActiveConfigPath) != nil

        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            let manager = (error == nil) ? managers?.first : nil
            let status: WidgetVPNStatus
            var effectiveLoginRequired = loginRequired

            let persistedRaw = defaults?.string(forKey: WidgetConstants.keyVPNStatus) ?? "disconnected"
            let persisted = WidgetVPNStatus(rawValue: persistedRaw) ?? .disconnected
            let startTime = defaults?.double(forKey: WidgetConstants.keyTransitionStartTime) ?? 0
            // startTime == 0 means the key was never written; treat both windows as active
            // (not expired) so snap-back protection is not bypassed on first load.
            let snapbackExpired: Bool
            let hardExpired: Bool
            if startTime > 0 {
                let elapsed = Date().timeIntervalSince1970 - startTime
                snapbackExpired = elapsed > WidgetConstants.snapbackWindow
                hardExpired     = elapsed > WidgetConstants.transitionMaxDuration
            } else {
                snapbackExpired = false
                hardExpired     = false
            }

            if let manager {
                let neStatus = WidgetVPNStatus(neStatus: manager.connection.status)

                if persisted.isTransitioning && hardExpired {
                    // Past the hard limit — force NE as truth regardless of snap-back.
                    status = neStatus
                    defaults?.set(neStatus.rawValue, forKey: WidgetConstants.keyVPNStatus)
                } else if persisted.isTransitioning && !snapbackExpired {
                    // NE caught up: it reports the same direction as our command (or the
                    // final settled state), or it moved in the opposite direction.
                    // In both cases NE has a definitive answer — trust it immediately.
                    let neResolved =
                        (persisted == .connecting  && (neStatus == .connecting  || neStatus == .connected))    ||
                        (persisted == .disconnecting && (neStatus == .disconnecting || neStatus == .disconnected)) ||
                        (persisted == .connecting  && neStatus == .disconnecting) ||
                        (persisted == .disconnecting && neStatus == .connecting)

                    if neResolved {
                        status = neStatus
                        defaults?.set(neStatus.rawValue, forKey: WidgetConstants.keyVPNStatus)
                    } else {
                        // NE still shows the old stable state — keep persisted transitioning
                        // state so the widget doesn't flicker back to stable prematurely.
                        status = persisted
                    }
                } else {
                    // Snap-back window expired (or persisted is already stable).
                    // NE is always the source of truth from here on.
                    status = neStatus
                    if persisted.isTransitioning {
                        defaults?.set(neStatus.rawValue, forKey: WidgetConstants.keyVPNStatus)
                    }
                }

                // Safety net: if NE reports connected the login-required flag must be stale.
                // PacketTunnelProvider also clears it in updateWidgetStatus("connected"), but
                // clearing here too ensures the widget self-heals even if that push was missed.
                if neStatus == .connected && loginRequired {
                    defaults?.set(false, forKey: WidgetConstants.keyLoginRequired)
                    effectiveLoginRequired = false
                }
            } else {
                // No NE manager (profile not configured, or NE error).
                // Fall back to persisted state; if transitioning and snap-back or hard
                // deadline expired, reset to disconnected so the widget never gets stuck.
                if persisted.isTransitioning && (snapbackExpired || hardExpired) {
                    status = .disconnected
                    defaults?.set(WidgetVPNStatus.disconnected.rawValue, forKey: WidgetConstants.keyVPNStatus)
                } else {
                    status = persisted
                }
            }

            let entry = VPNStatusEntry(
                date: Date(),
                status: status,
                ip: ip,
                fqdn: fqdn,
                needsAppSetup: manager == nil || !configPathStored || effectiveLoginRequired,
                loginRequired: effectiveLoginRequired
            )
            completion(entry)
        }
    }
}
