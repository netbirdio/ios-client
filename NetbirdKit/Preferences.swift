//
//  Preferences.swift
//  NetBirdiOS
//
//  Created by Pascal Fischer on 03.08.23.
//

import Foundation
import NetBirdSDK

class Preferences {
    #if os(tvOS)
    static let appGroupIdentifier = "group.io.netbird.app.tv"
    #else
    static let appGroupIdentifier = "group.io.netbird.app"
    #endif

    static func newPreferences() -> NetBirdSDKPreferences? {
        #if os(tvOS)
        // On tvOS, creating SDK Preferences may fail if the app doesn't have write access
        // to the App Group container. Try anyway - if it fails, settings will be managed
        // via the extension instead.
        // Note: The SDK now uses DirectWriteOutConfig which may work better on tvOS.
        return NetBirdSDKNewPreferences(configFile(), stateFile())
        #else
        return NetBirdSDKNewPreferences(configFile(), stateFile())
        #endif
    }

    static func configFile() -> String {
        let fileManager = FileManager.default
        let groupURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
        let logURL = groupURL?.appendingPathComponent("netbird.cfg")
        return logURL!.relativePath
    }

    static func stateFile() -> String {
        let fileManager = FileManager.default
        let groupURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
        let logURL = groupURL?.appendingPathComponent("state.json")
        return logURL!.relativePath
    }

    // UserDefaults-based config storage for tvOS
    // tvOS sandbox prevents file writes to App Group containers, so we use UserDefaults instead

    private static let configJSONKey = "netbird_config_json"

    /// Get the shared UserDefaults for the App Group
    static func sharedUserDefaults() -> UserDefaults? {
        return UserDefaults(suiteName: appGroupIdentifier)
    }

    /// Save config JSON to UserDefaults (works on tvOS where file writes fail)
    static func saveConfigToUserDefaults(_ configJSON: String) -> Bool {
        guard let defaults = sharedUserDefaults() else {
            print("Preferences: Failed to get shared UserDefaults")
            return false
        }
        defaults.set(configJSON, forKey: configJSONKey)
        defaults.synchronize()
        print("Preferences: Saved config to UserDefaults (\(configJSON.count) bytes)")
        return true
    }

    /// Load config JSON from UserDefaults
    static func loadConfigFromUserDefaults() -> String? {
        guard let defaults = sharedUserDefaults() else {
            print("Preferences: Failed to get shared UserDefaults")
            return nil
        }
        let config = defaults.string(forKey: configJSONKey)
        if let config = config {
            print("Preferences: Loaded config from UserDefaults (\(config.count) bytes)")
        } else {
            print("Preferences: No config found in UserDefaults")
        }
        return config
    }

    /// Check if config exists in UserDefaults
    static func hasConfigInUserDefaults() -> Bool {
        guard let defaults = sharedUserDefaults() else {
            return false
        }
        return defaults.string(forKey: configJSONKey) != nil
    }

    /// Remove config from UserDefaults (for logout)
    static func removeConfigFromUserDefaults() {
        guard let defaults = sharedUserDefaults() else {
            return
        }
        defaults.removeObject(forKey: configJSONKey)
        defaults.synchronize()
        print("Preferences: Removed config from UserDefaults")
    }

    /// Restore config from UserDefaults to the config file path
    /// This is needed because the Go SDK reads from the file path
    /// Returns true if config was restored successfully
    static func restoreConfigFromUserDefaults() -> Bool {
        guard let configJSON = loadConfigFromUserDefaults() else {
            return false
        }

        let path = configFile()
        do {
            try configJSON.write(toFile: path, atomically: false, encoding: .utf8)
            print("Preferences: Restored config to file: \(path)")
            return true
        } catch {
            print("Preferences: Failed to write config to file: \(error.localizedDescription)")
            return false
        }
    }
}

