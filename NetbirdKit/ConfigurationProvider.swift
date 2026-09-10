//
//  ConfigurationProvider.swift
//  NetBird
//
//  Protocol abstraction for platform-specific configuration management.
//  iOS uses SDK file-based preferences, tvOS uses IPC-based config transfer.
//

import Foundation
import NetBirdSDK

// MARK: - Protocol Definition

/// Abstracts platform-specific configuration storage and retrieval.
/// - iOS: Uses NetBirdSDKPreferences with file-based storage in App Group container
/// - tvOS: Uses UserDefaults + IPC transfer (App Group files don't work between app/extension)
protocol ConfigurationProvider {
    // MARK: - Rosenpass Settings

    /// Whether Rosenpass (post-quantum encryption) is enabled
    var rosenpassEnabled: Bool { get set }

    /// Whether Rosenpass permissive mode is enabled (allows non-Rosenpass peers)
    var rosenpassPermissive: Bool { get set }

    // MARK: - IPv6

    /// Whether IPv6 overlay addressing is disabled
    var disableIPv6: Bool { get set }

    // MARK: - Pre-Shared Key

    /// Stages a new pre-shared key; an empty string clears it. Write-only by
    /// design: the Go layer no longer hands the key back across the bridge, so
    /// there is no matching getter.
    func setPreSharedKey(_ key: String)

    /// Whether a pre-shared key is configured - staged, persisted, or enforced
    /// by MDM policy.
    var hasPreSharedKey: Bool { get }

    // MARK: - Lifecycle

    /// Commits any pending changes to persistent storage
    /// Returns true on success, false on failure
    @discardableResult
    func commit() -> Bool

    /// Message from the most recent failed commit, or nil after a success.
    /// The Go layer rejects a staged value that diverges from an MDM-managed
    /// key, and the caller needs the reason to tell that apart from an I/O
    /// failure.
    var lastCommitError: String? { get }

    /// Reloads settings from persistent storage
    func reload()
}

// MARK: - iOS Implementation

#if os(iOS)
/// iOS implementation using NetBirdSDKPreferences (file-based storage)
final class iOSConfigurationProvider: ConfigurationProvider {

    private var preferences: NetBirdSDKPreferences
    private(set) var lastCommitError: String?

    init() {
        self.preferences = Preferences.newPreferences()
    }

    // MARK: - Rosenpass

    var rosenpassEnabled: Bool {
        get {
            var result = ObjCBool(false)
            do {
                try preferences.getRosenpassEnabled(&result)
            } catch {
                print("ConfigurationProvider: Failed to read rosenpassEnabled - \(error)")
            }
            return result.boolValue
        }
        set {
            preferences.setRosenpassEnabled(newValue)
        }
    }

    var rosenpassPermissive: Bool {
        get {
            var result = ObjCBool(false)
            do {
                try preferences.getRosenpassPermissive(&result)
            } catch {
                print("ConfigurationProvider: Failed to read rosenpassPermissive - \(error)")
            }
            return result.boolValue
        }
        set {
            preferences.setRosenpassPermissive(newValue)
        }
    }

    // MARK: - IPv6

    var disableIPv6: Bool {
        get {
            var result = ObjCBool(false)
            do {
                try preferences.getDisableIPv6(&result)
            } catch {
                print("ConfigurationProvider: Failed to read disableIPv6 - \(error)")
            }
            return result.boolValue
        }
        set {
            preferences.setDisableIPv6(newValue)
        }
    }

    // MARK: - Pre-Shared Key

    func setPreSharedKey(_ key: String) {
        preferences.setPreSharedKey(key)
    }

    var hasPreSharedKey: Bool {
        var result = ObjCBool(false)
        do {
            try preferences.hasPreSharedKey(&result)
        } catch {
            print("ConfigurationProvider: Failed to read hasPreSharedKey - \(error)")
        }
        return result.boolValue
    }

    // MARK: - Lifecycle

    @discardableResult
    func commit() -> Bool {
        do {
            try preferences.commit()
            lastCommitError = nil
            return true
        } catch {
            lastCommitError = error.localizedDescription
            print("ConfigurationProvider: Failed to commit - \(error)")
            return false
        }
    }

    func reload() {
        // Only recreate preferences if the config file exists.
        // If the config was deleted by a logout, NetBirdSDKNewPreferences would create
        // a new file with the default server URL (api.netbird.io), overwriting any
        // saved custom server URL in netbird_server_url.
        guard let configPath = Preferences.configFile(),
              FileManager.default.fileExists(atPath: configPath) else {
            return
        }
        self.preferences = Preferences.newPreferences()
    }
}
#endif

// MARK: - tvOS Implementation

#if os(tvOS)
/// tvOS implementation that reads/writes settings directly to the config JSON.
/// This mirrors iOS behavior where all settings live in one config file.
/// The config JSON is stored in UserDefaults and sent to the extension via IPC.
final class tvOSConfigurationProvider: ConfigurationProvider {

    init() {}

    /// Reason the most recent write was refused, or nil.
    private var refusal: String?

    /// Refuses a write the policy owns.
    ///
    /// iOS reaches Go's CheckMDMConflicts through Preferences.commit(); tvOS
    /// writes straight to the config JSON and never crosses that bridge, so
    /// without this gate a managed field would stay writable here while iOS
    /// rejects it. `key` names the field the way the Go error does, so the
    /// message a user sees is the same on both platforms.
    private func policyRefuses(_ key: String, managedBy: (MDMRestrictions.Fields) -> Bool) -> Bool {
        // One snapshot per write. Reading the field's own flag separately from
        // the blanket gate would let a policy landing between the two reads
        // slip a managed write through on the stale value - and it costs a
        // second trip across the bridge for nothing.
        let restrictions = MDMRestrictions.current()
        guard managedBy(restrictions.mdm) || restrictions.features.disableUpdateSettings else {
            return false
        }
        refusal = "fields managed by MDM cannot be modified: [\(key)]"
        AppLogger.shared.log("ConfigurationProvider: refused a write to \(key) — managed by MDM policy")
        return true
    }

    // MARK: - Rosenpass

    var rosenpassEnabled: Bool {
        get { extractJSONBool(field: "RosenpassEnabled") ?? false }
        set {
            guard !policyRefuses("rosenpassEnabled", managedBy: { $0.rosenpassEnabled }) else { return }
            updateJSONField(field: "RosenpassEnabled", value: newValue)
        }
    }

    var rosenpassPermissive: Bool {
        get { extractJSONBool(field: "RosenpassPermissive") ?? false }
        set {
            guard !policyRefuses("rosenpassPermissive", managedBy: { $0.rosenpassPermissive }) else { return }
            updateJSONField(field: "RosenpassPermissive", value: newValue)
        }
    }

    // MARK: - IPv6

    var disableIPv6: Bool {
        get { extractJSONBool(field: "DisableIPv6") ?? false }
        set {
            // No MDM key of its own; only the blanket settings gate applies.
            guard !policyRefuses("disableIPv6", managedBy: { _ in false }) else { return }
            updateJSONField(field: "DisableIPv6", value: newValue)
        }
    }

    // MARK: - Pre-Shared Key

    func setPreSharedKey(_ key: String) {
        guard !policyRefuses("preSharedKey", managedBy: { $0.preSharedKey }) else { return }
        updateJSONField(field: "PreSharedKey", value: key)
    }

    var hasPreSharedKey: Bool {
        // A policy-supplied key never reaches the local config JSON, so
        // reading only that would report "Not configured" for a device the
        // policy has in fact given a key.
        if MDMRestrictions.current().mdm.preSharedKey {
            return true
        }
        return !(extractJSONString(field: "PreSharedKey") ?? "").isEmpty
    }

    // MARK: - Lifecycle

    @discardableResult
    func commit() -> Bool {
        // Settings are written straight to the config JSON, so there is no
        // separate commit to make — but a write the policy refused must still
        // be reported, since callers treat commit() as the success signal.
        lastCommitError = refusal
        defer { refusal = nil }
        return refusal == nil
    }

    private(set) var lastCommitError: String?

    func reload() {
        // Config JSON is always read fresh from UserDefaults
    }

    // MARK: - JSON Helpers (read/write to stored config)

    private func getConfigJSON() -> String? {
        return Preferences.loadConfigFromUserDefaults()
    }

    private func saveConfigJSON(_ json: String) {
        _ = Preferences.saveConfigToUserDefaults(json)
    }

    private func parseConfigDict() -> [String: Any]? {
        guard let json = getConfigJSON(),
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return dict
    }

    private func extractJSONBool(field: String) -> Bool? {
        return parseConfigDict()?[field] as? Bool
    }

    private func extractJSONString(field: String) -> String? {
        return parseConfigDict()?[field] as? String
    }

    private func updateJSONField<T>(field: String, value: T) {
        guard var dict = parseConfigDict() else {
            AppLogger.shared.log("ConfigurationProvider: No config JSON available for updating '\(field)'")
            return
        }

        dict[field] = value

        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            AppLogger.shared.log("ConfigurationProvider: Failed to serialize config JSON")
            return
        }

        saveConfigJSON(json)
    }
}
#endif

// MARK: - Factory

/// Factory for creating the appropriate ConfigurationProvider for the current platform
enum ConfigurationProviderFactory {
    static func create() -> ConfigurationProvider {
        #if os(iOS)
        return iOSConfigurationProvider()
        #else
        return tvOSConfigurationProvider()
        #endif
    }
}
