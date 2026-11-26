import AppIntents
import NetworkExtension
import WidgetKit

/// Shared helpers used across all VPN intents.
@available(iOS 16.0, *)
enum VPNIntentHelpers {

    static func loadManager() async throws -> NETunnelProviderManager? {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        if let first = managers.first { return first }

        // On first widget process startup NE preferences can return empty; retry once.
        try await Task.sleep(nanoseconds: 300_000_000)
        return try await NETunnelProviderManager.loadAllFromPreferences().first
    }

    static var defaults: UserDefaults? {
        UserDefaults(suiteName: WidgetConstants.appGroupSuite)
    }

    static var isLoginRequired: Bool {
        defaults?.bool(forKey: WidgetConstants.keyLoginRequired) ?? false
    }

    /// Enables the NetBird configuration if the system disabled it, which happens
    /// whenever another VPN app was used since the last NetBird connection.
    /// Starting a disabled configuration fails with `configurationDisabled`.
    static func enableIfNeeded(manager: NETunnelProviderManager) async throws {
        guard !manager.isEnabled else { return }
        manager.isEnabled = true
        try await manager.saveToPreferences()
        // A saved manager must be reloaded before its tunnel can be started.
        try await manager.loadFromPreferences()
    }

    /// Enables the configuration if needed, then starts the tunnel.
    static func startTunnel(manager: NETunnelProviderManager) async throws {
        try await enableIfNeeded(manager: manager)
        guard let session = manager.connection as? NETunnelProviderSession else {
            throw NEVPNError(.configurationInvalid)
        }
        try startTunnel(session: session)
    }

    /// Starts the VPN tunnel with the active profile paths so PacketTunnelProvider
    /// can locate the correct config file even when the main app is not running.
    /// Returns an error if startVPNTunnel fails (callers should handle/log it).
    @discardableResult
    static func startTunnel(session: NETunnelProviderSession) throws -> Bool {
        var options: [String: NSObject] = [:]
        if let configPath = defaults?.string(forKey: WidgetConstants.keyActiveConfigPath) {
            options["configPath"] = configPath as NSObject
        }
        if let statePath = defaults?.string(forKey: WidgetConstants.keyActiveStatePath) {
            options["statePath"] = statePath as NSObject
        }
        try session.startVPNTunnel(options: options.isEmpty ? nil : options)
        return true
    }

    @discardableResult
    static func waitForStableState(manager: NETunnelProviderManager) async -> WidgetVPNStatus {
        let deadline = Date().addingTimeInterval(WidgetConstants.pollTimeout)
        let initialStatus = WidgetVPNStatus(neStatus: manager.connection.status)
        var seenTransition = false

        while Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(WidgetConstants.pollInterval * 1_000_000_000))

            if isLoginRequired {
                let current = WidgetVPNStatus(neStatus: manager.connection.status)
                defaults?.set(current.rawValue, forKey: WidgetConstants.keyVPNStatus)
                WidgetCenter.shared.reloadAllTimelines()
                return current
            }

            let current = WidgetVPNStatus(neStatus: manager.connection.status)
            if current != initialStatus { seenTransition = true }
            if seenTransition && current.isStable { break }
        }

        let final = WidgetVPNStatus(neStatus: manager.connection.status)
        defaults?.set(final.rawValue, forKey: WidgetConstants.keyVPNStatus)
        WidgetCenter.shared.reloadAllTimelines()
        return final
    }
}
