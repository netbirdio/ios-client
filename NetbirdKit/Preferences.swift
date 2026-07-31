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
    /// Creates SDK preferences using the active profile's config/state paths.
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
        #if os(iOS)
        // Use profile-aware paths on iOS
        return ProfileManager.shared.activeConfigPath()
        #else
        return getFilePath(fileName: GlobalConstants.configFileName)
        #endif
    }

    static func stateFile() -> String? {
        #if os(iOS)
        // Use profile-aware paths on iOS
        return ProfileManager.shared.activeStatePath()
        #else
        return getFilePath(fileName: GlobalConstants.stateFileName)
        #endif
    }

    /// Returns a writable directory for debug bundle ZIP generation.
    /// iOS: App Group container's Caches subdir. tvOS: system temp dir.
    static func cacheDirectory() -> String {
        let fileManager = FileManager.default
        #if os(tvOS)
        return fileManager.temporaryDirectory.path
        #else
        if let groupURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: GlobalConstants.userPreferencesSuiteName) {
            let cacheURL = groupURL.appendingPathComponent("Library/Caches/netbird-debug")
            do {
                try fileManager.createDirectory(at: cacheURL, withIntermediateDirectories: true)
                return cacheURL.path
            } catch {
                return fileManager.temporaryDirectory.path
            }
        }
        return fileManager.temporaryDirectory.path
        #endif
    }

    static func logFilePath() -> String? {
        return FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: GlobalConstants.userPreferencesSuiteName)?
            .appendingPathComponent("logfile.log")
            .path
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
        defaults.removeObject(forKey: managementURLKey)
        defaults.synchronize()
    }

    // MARK: - Management URL Storage
    //
    // Stored separately because the config JSON from Go SDK serializes ManagementURL
    // as a nested object (not a plain string), making regex/JSON extraction unreliable.

    private static let managementURLKey = "netbird_management_url"

    /// Save the management URL explicitly (called when user changes server).
    static func saveManagementURL(_ url: String) {
        sharedUserDefaults()?.set(url, forKey: managementURLKey)
        sharedUserDefaults()?.synchronize()
    }

    /// Load the explicitly saved management URL.
    static func loadManagementURL() -> String? {
        return sharedUserDefaults()?.string(forKey: managementURLKey)
    }

    // MARK: - Fresh Browser Session

    /// Whether the stored browser session must not be reused by the next login.
    static func needsFreshBrowserSession() -> Bool {
        return sharedUserDefaults()?.bool(forKey: GlobalConstants.keyNeedsFreshBrowserSession) ?? false
    }

    /// Requires the next login to start a fresh browser session. Set on logout, so
    /// signing back in cannot silently reuse the session that was just logged out of.
    static func setNeedsFreshBrowserSession() {
        sharedUserDefaults()?.set(true, forKey: GlobalConstants.keyNeedsFreshBrowserSession)
    }

    /// Clears the requirement once a login has run with a fresh session.
    static func clearNeedsFreshBrowserSession() {
        sharedUserDefaults()?.removeObject(forKey: GlobalConstants.keyNeedsFreshBrowserSession)
    }

    // MARK: - Last Authenticated Profile
    //
    // The login browser (ASWebAuthenticationSession) shares Safari's cookie jar,
    // which the app cannot scope per profile or clear. Recording which profile that
    // jar was last authenticated for lets the adapter add prompt=select_account
    // whenever a login targets a different profile, so the IdP re-asks which
    // account to use instead of silently signing in the previous one.

    /// Records the profile the login browser last authenticated.
    static func saveLastAuthenticatedProfile(_ name: String) {
        sharedUserDefaults()?.set(name, forKey: GlobalConstants.keyLastAuthenticatedProfile)
    }

    /// The profile the login browser last authenticated, or nil if none has yet.
    static func loadLastAuthenticatedProfile() -> String? {
        return sharedUserDefaults()?.string(forKey: GlobalConstants.keyLastAuthenticatedProfile)
    }

    /// Forgets the marker if it names `profile`. Called on logout and profile
    /// removal so the next login re-asks which account to use.
    static func clearLastAuthenticatedProfile(ifEquals profile: String) {
        guard let defaults = sharedUserDefaults() else { return }
        if defaults.string(forKey: GlobalConstants.keyLastAuthenticatedProfile) == profile {
            defaults.removeObject(forKey: GlobalConstants.keyLastAuthenticatedProfile)
        }
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
