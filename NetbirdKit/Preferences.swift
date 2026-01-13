//
//  Preferences.swift
//  NetBirdiOS
//
//  Created by Pascal Fischer on 03.08.23.
//

import Foundation
import NetBirdSDK

/// Preferences manages configuration file paths and SDK preferences.
///
/// ## Platform Differences
///
/// ### iOS
/// Uses file-based storage via App Group shared container. The main app and extension
/// can both read/write files to this shared location.
///
/// ### tvOS
/// The App Group shared container does NOT work for IPC between the main app and
/// Network Extension due to sandbox restrictions. Config is transferred via IPC
/// (`sendProviderMessage`/`handleAppMessage`) instead. The SDK preferences are not
/// used on tvOS - settings are managed directly in the extension.
///
/// See NetworkExtensionAdapter and PacketTunnelProvider for tvOS config flow details.
class Preferences {

    // MARK: - SDK Preferences

    #if os(iOS)
    /// Creates SDK preferences using App Group shared container paths.
    /// iOS only - file-based storage works reliably.
    static func newPreferences() -> NetBirdSDKPreferences {
        guard let configPath = configFile(), let statePath = stateFile() else {
            preconditionFailure("App group container unavailable - check entitlements for '\(GlobalConstants.userPreferencesSuiteName)'")
        }
        guard let preferences = NetBirdSDKNewPreferences(configPath, statePath) else {
            preconditionFailure("Failed to create NetBirdSDKPreferences")
        }
        return preferences
    }
    #else
    /// tvOS does not use SDK preferences - config is transferred via IPC.
    /// Returns nil by design; callers must handle this case.
    static func newPreferences() -> NetBirdSDKPreferences? {
        // tvOS uses IPC-based config transfer, not file-based SDK preferences.
        // The extension manages its own config via UserDefaults.standard after
        // receiving it through handleAppMessage.
        return nil
    }
    #endif

    // MARK: - File Paths

    /// Returns the file path for a given filename in the App Group container.
    /// Returns nil if the container is unavailable.
    static func getFilePath(fileName: String) -> String? {
        let fileManager = FileManager.default
        if let groupURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: GlobalConstants.userPreferencesSuiteName) {
            return groupURL.appendingPathComponent(fileName).path
        }

        #if DEBUG
        // Fallback for testing when app group is not available
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
        return (baseURL ?? fileManager.temporaryDirectory).appendingPathComponent(fileName).path
        #else
        AppLogger.shared.log("ERROR: App group '\(GlobalConstants.userPreferencesSuiteName)' not available. Check entitlements.")
        return nil
        #endif
    }

    static func configFile() -> String? {
        return getFilePath(fileName: GlobalConstants.configFileName)
    }

    static func stateFile() -> String? {
        return getFilePath(fileName: GlobalConstants.stateFileName)
    }

    // MARK: - App-Local UserDefaults Storage
    //
    // These methods store config in the App Group UserDefaults for the MAIN APP's
    // own use (e.g., displaying current server URL). On tvOS, this data is NOT
    // shared with the extension - it's app-local only.

    private static let configJSONKey = "netbird_config_json"

    /// Get the App Group UserDefaults.
    /// Note: On tvOS, this is app-local only - NOT shared with extension.
    static func sharedUserDefaults() -> UserDefaults? {
        return UserDefaults(suiteName: GlobalConstants.userPreferencesSuiteName)
    }

    /// Save config JSON to UserDefaults (app-local storage).
    static func saveConfigToUserDefaults(_ configJSON: String) -> Bool {
        guard let defaults = sharedUserDefaults() else {
            return false
        }
        defaults.set(configJSON, forKey: configJSONKey)
        defaults.synchronize()
        return true
    }

    /// Load config JSON from UserDefaults (app-local storage).
    static func loadConfigFromUserDefaults() -> String? {
        return sharedUserDefaults()?.string(forKey: configJSONKey)
    }

    /// Check if config exists in UserDefaults.
    static func hasConfigInUserDefaults() -> Bool {
        return sharedUserDefaults()?.string(forKey: configJSONKey) != nil
    }

    /// Remove config from UserDefaults (for logout).
    static func removeConfigFromUserDefaults() {
        guard let defaults = sharedUserDefaults() else {
            return
        }
        defaults.removeObject(forKey: configJSONKey)
        defaults.synchronize()
    }

    /// Restore config from UserDefaults to the config file path.
    /// iOS only - needed because the Go SDK reads from the file path.
    #if os(iOS)
    static func restoreConfigFromUserDefaults() -> Bool {
        guard let configJSON = loadConfigFromUserDefaults(),
              let path = configFile() else {
            return false
        }
        do {
            try configJSON.write(toFile: path, atomically: false, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }
    #endif
}
