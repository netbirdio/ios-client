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

    // MARK: - Pre-Shared Key

    /// The current pre-shared key (empty string if not set)
    var preSharedKey: String { get set }

    /// Whether a pre-shared key is configured
    var hasPreSharedKey: Bool { get }

    // MARK: - Lifecycle

    /// Commits any pending changes to persistent storage
    /// Returns true on success, false on failure
    @discardableResult
    func commit() -> Bool

    /// Reloads settings from persistent storage
    func reload()
}

// MARK: - iOS Implementation

#if os(iOS)
/// iOS implementation using NetBirdSDKPreferences (file-based storage)
final class iOSConfigurationProvider: ConfigurationProvider {

    private var preferences: NetBirdSDKPreferences

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

    // MARK: - Pre-Shared Key

    var preSharedKey: String {
        get {
            return preferences.getPreSharedKey(nil)
        }
        set {
            preferences.setPreSharedKey(newValue)
        }
    }

    var hasPreSharedKey: Bool {
        return !preSharedKey.isEmpty
    }

    // MARK: - Lifecycle

    @discardableResult
    func commit() -> Bool {
        do {
            try preferences.commit()
            return true
        } catch {
            print("ConfigurationProvider: Failed to commit - \(error)")
            return false
        }
    }

    func reload() {
        // Recreate preferences to pick up new config file after server change
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

    // MARK: - Rosenpass

    var rosenpassEnabled: Bool {
        get { extractJSONBool(field: "RosenpassEnabled") ?? false }
        set { updateJSONField(field: "RosenpassEnabled", value: newValue) }
    }

    var rosenpassPermissive: Bool {
        get { extractJSONBool(field: "RosenpassPermissive") ?? false }
        set { updateJSONField(field: "RosenpassPermissive", value: newValue) }
    }

    // MARK: - Pre-Shared Key

    var preSharedKey: String {
        get { extractJSONString(field: "PreSharedKey") ?? "" }
        set { updateJSONStringField(field: "PreSharedKey", value: newValue) }
    }

    var hasPreSharedKey: Bool {
        return !preSharedKey.isEmpty
    }

    // MARK: - Lifecycle

    @discardableResult
    func commit() -> Bool {
        // Settings are written directly to config JSON, no separate commit needed
        return true
    }

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

    private func updateJSONField(field: String, value: Bool) {
        guard var dict = parseConfigDict() else {
            AppLogger.shared.log("ConfigurationProvider: No config JSON available for updating '\(field)'")
            return
        }

        guard dict[field] != nil else {
            AppLogger.shared.log("ConfigurationProvider: Field '\(field)' not found in config JSON")
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

    private func updateJSONStringField(field: String, value: String) {
        guard var dict = parseConfigDict() else {
            AppLogger.shared.log("ConfigurationProvider: No config JSON available for updating '\(field)'")
            return
        }

        guard dict[field] != nil else {
            AppLogger.shared.log("ConfigurationProvider: Field '\(field)' not found in config JSON")
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
