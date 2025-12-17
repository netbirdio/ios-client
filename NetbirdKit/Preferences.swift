//
//  Preferences.swift
//  NetBirdiOS
//
//  Created by Pascal Fischer on 03.08.23.
//

import Foundation
import NetBirdSDK

/// Preferences manages configuration file paths and UserDefaults-based config storage.
///
/// ## tvOS Config Storage Architecture
///
/// On tvOS, the standard App Group shared container does NOT work for IPC between the main app
/// and the Network Extension due to sandbox restrictions. The error you'll see is:
/// `Using kCFPreferencesAnyUser with a container is only allowed for System Containers`
///
/// To work around this, tvOS uses a different architecture:
///
/// ### Config Flow on tvOS:
/// 1. **Main App** → User enters server URL in TVServerView
/// 2. **Main App** → ServerViewModel saves config to shared UserDefaults (`saveConfigToUserDefaults`)
///    - This step is for the main app's own reference only
/// 3. **Main App** → NetworkExtensionAdapter sends config via IPC (`sendConfigToExtension`)
///    - Uses `sendProviderMessage` with "SetConfig:{json}" format
/// 4. **Extension** → PacketTunnelProvider receives config via `handleAppMessage`
/// 5. **Extension** → Saves to extension-local UserDefaults (`UserDefaults.standard`)
///    - Key: "netbird_config_json_local"
///    - This is the authoritative source for the extension
/// 6. **Extension** → NetBirdAdapter.init() loads from extension-local UserDefaults
///
/// ### Key Points:
/// - Shared App Group UserDefaults does NOT work between app and extension on tvOS
/// - Extension-local `UserDefaults.standard` is the authoritative config source for the extension
/// - Config must be transferred via IPC using `sendProviderMessage`/`handleAppMessage`
/// - The main app's shared UserDefaults is only for the app's own use (e.g., displaying current URL)
///
/// ### iOS Behavior:
/// On iOS, file-based config storage works normally via the App Group container.
/// The UserDefaults methods here are primarily for tvOS compatibility.
class Preferences {
    #if os(tvOS)
    static let appGroupIdentifier = "group.io.netbird.app.tv"
    #else
    static let appGroupIdentifier = "group.io.netbird.app"
    #endif

    static func newPreferences() -> NetBirdSDKPreferences? {
        guard let configPath = configFile(), let statePath = stateFile() else {
            print("ERROR: Cannot create preferences - app group container unavailable")
            return nil
        }
        #if os(tvOS)
        // On tvOS, creating SDK Preferences may fail if the app doesn't have write access
        // to the App Group container. Try anyway - if it fails, settings will be managed
        // via the extension instead.
        // Note: The SDK now uses DirectWriteOutConfig which may work better on tvOS.
        return NetBirdSDKNewPreferences(configPath, statePath)
        #else
        return NetBirdSDKNewPreferences(configPath, statePath)
        #endif
    }

    static func configFile() -> String? {
        let fileManager = FileManager.default
        guard let groupURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            print("ERROR: App group '\(appGroupIdentifier)' not available. Check entitlements.")
            return nil
        }
        return groupURL.appendingPathComponent("netbird.cfg").path
    }

    static func stateFile() -> String? {
        let fileManager = FileManager.default
        guard let groupURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            print("ERROR: App group '\(appGroupIdentifier)' not available. Check entitlements.")
            return nil
        }
        return groupURL.appendingPathComponent("state.json").path
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
            return false
        }
        defaults.set(configJSON, forKey: configJSONKey)
        defaults.synchronize()
        return true
    }

    /// Load config JSON from UserDefaults
    static func loadConfigFromUserDefaults() -> String? {
        guard let defaults = sharedUserDefaults() else {
            return nil
        }
        return defaults.string(forKey: configJSONKey)
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
    }

    /// Restore config from UserDefaults to the config file path
    /// This is needed because the Go SDK reads from the file path
    static func restoreConfigFromUserDefaults() -> Bool {
        guard let configJSON = loadConfigFromUserDefaults() else {
            return false
        }

        guard let path = configFile() else {
            print("ERROR: Cannot restore config - app group container unavailable")
            return false
        }
        do {
            try configJSON.write(toFile: path, atomically: false, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }
}

