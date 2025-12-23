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

    private func extractJSONBool(field: String) -> Bool? {
        guard let json = getConfigJSON() else { return nil }
        let pattern = "\"\(field)\"\\s*:\\s*(true|false)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: json, options: [], range: NSRange(json.startIndex..., in: json)),
              let valueRange = Range(match.range(at: 1), in: json) else {
            return nil
        }
        return String(json[valueRange]) == "true"
    }

    private func extractJSONString(field: String) -> String? {
        guard let json = getConfigJSON() else { return nil }
        let pattern = "\"\(field)\"\\s*:\\s*\"([^\"]*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: json, options: [], range: NSRange(json.startIndex..., in: json)),
              let valueRange = Range(match.range(at: 1), in: json) else {
            return nil
        }
        return String(json[valueRange])
    }

    private func updateJSONField(field: String, value: Bool) {
        guard var json = getConfigJSON() else { return }

        let pattern = "\"\(field)\"\\s*:\\s*(true|false)"
        let replacement = "\"\(field)\":\(value)"

        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let range = NSRange(json.startIndex..., in: json)
            if regex.firstMatch(in: json, options: [], range: range) != nil {
                json = regex.stringByReplacingMatches(in: json, options: [], range: range, withTemplate: replacement)
                saveConfigJSON(json)
            }
        }
    }

    private func updateJSONStringField(field: String, value: String) {
        guard var json = getConfigJSON() else { return }

        let escapedValue = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let pattern = "\"\(field)\"\\s*:\\s*\"[^\"]*\""
        let replacement = "\"\(field)\":\"\(escapedValue)\""

        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let range = NSRange(json.startIndex..., in: json)
            json = regex.stringByReplacingMatches(in: json, options: [], range: range, withTemplate: replacement)
            saveConfigJSON(json)
        }
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
