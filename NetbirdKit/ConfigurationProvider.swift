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
/// tvOS implementation using UserDefaults + config JSON manipulation
/// Settings are stored locally and injected into config JSON before IPC transfer
final class tvOSConfigurationProvider: ConfigurationProvider {

    private let defaults = UserDefaults.standard

    // UserDefaults keys for tvOS-local settings
    private enum Keys {
        static let rosenpassEnabled = "netbird_rosenpass_enabled"
        static let rosenpassPermissive = "netbird_rosenpass_permissive"
        static let preSharedKey = "netbird_preshared_key"
    }

    init() {}

    // MARK: - Rosenpass

    var rosenpassEnabled: Bool {
        get { defaults.bool(forKey: Keys.rosenpassEnabled) }
        set { defaults.set(newValue, forKey: Keys.rosenpassEnabled) }
    }

    var rosenpassPermissive: Bool {
        get { defaults.bool(forKey: Keys.rosenpassPermissive) }
        set { defaults.set(newValue, forKey: Keys.rosenpassPermissive) }
    }

    // MARK: - Pre-Shared Key

    var preSharedKey: String {
        get { defaults.string(forKey: Keys.preSharedKey) ?? "" }
        set { defaults.set(newValue, forKey: Keys.preSharedKey) }
    }

    var hasPreSharedKey: Bool {
        return !preSharedKey.isEmpty
    }

    // MARK: - Lifecycle

    @discardableResult
    func commit() -> Bool {
        defaults.synchronize()
        // On tvOS, settings are applied when the config JSON is transferred via IPC
        // The actual injection happens in applySettingsToConfig()
        return true
    }

    func reload() {
        // UserDefaults are always fresh, no explicit reload needed
    }

    // MARK: - Config JSON Integration

    /// Applies current settings to a config JSON string.
    /// Called before transferring config to the extension via IPC.
    func applySettingsToConfig(_ configJSON: String) -> String {
        var result = configJSON
        result = updateJSONField(result, field: "RosenpassEnabled", value: rosenpassEnabled)
        result = updateJSONField(result, field: "RosenpassPermissive", value: rosenpassPermissive)
        if hasPreSharedKey {
            result = updateJSONStringField(result, field: "PreSharedKey", value: preSharedKey)
        }
        return result
    }

    /// Extracts settings from a config JSON string and stores them locally.
    /// Called after receiving config from the extension.
    func extractSettingsFromConfig(_ configJSON: String) {
        if let enabled = extractJSONBool(configJSON, field: "RosenpassEnabled") {
            rosenpassEnabled = enabled
        }
        if let permissive = extractJSONBool(configJSON, field: "RosenpassPermissive") {
            rosenpassPermissive = permissive
        }
        if let key = extractJSONString(configJSON, field: "PreSharedKey"), !key.isEmpty {
            preSharedKey = key
        }
    }

    // MARK: - JSON Helpers

    private func updateJSONField(_ json: String, field: String, value: Bool) -> String {
        let pattern = "\"\(field)\"\\s*:\\s*(true|false)"
        let replacement = "\"\(field)\":\(value)"

        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let range = NSRange(json.startIndex..., in: json)
            if regex.firstMatch(in: json, options: [], range: range) != nil {
                return regex.stringByReplacingMatches(in: json, options: [], range: range, withTemplate: replacement)
            }
        }

        // Field doesn't exist - insert before closing brace
        // This is a simple approach; a proper JSON parser would be more robust
        return json
    }

    private func updateJSONStringField(_ json: String, field: String, value: String) -> String {
        let escapedValue = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let pattern = "\"\(field)\"\\s*:\\s*\"[^\"]*\""
        let replacement = "\"\(field)\":\"\(escapedValue)\""

        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let range = NSRange(json.startIndex..., in: json)
            return regex.stringByReplacingMatches(in: json, options: [], range: range, withTemplate: replacement)
        }
        return json
    }

    private func extractJSONBool(_ json: String, field: String) -> Bool? {
        let pattern = "\"\(field)\"\\s*:\\s*(true|false)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: json, options: [], range: NSRange(json.startIndex..., in: json)),
              let valueRange = Range(match.range(at: 1), in: json) else {
            return nil
        }
        return String(json[valueRange]) == "true"
    }

    private func extractJSONString(_ json: String, field: String) -> String? {
        let pattern = "\"\(field)\"\\s*:\\s*\"([^\"]*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: json, options: [], range: NSRange(json.startIndex..., in: json)),
              let valueRange = Range(match.range(at: 1), in: json) else {
            return nil
        }
        return String(json[valueRange])
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
