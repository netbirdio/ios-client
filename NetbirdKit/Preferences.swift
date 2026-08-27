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
        // Fallback for testing when app group is not available.
        // On tvOS ~/Library/Application Support is read-only in the sandbox —
        // use Caches (writable) so the Go SDK doesn't fail with EPERM.
        #if os(tvOS)
        let baseURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
        #else
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
        #endif
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
        #elseif os(tvOS)
        // App Group container is not writable on tvOS, so the config path handed
        // to NetBirdSDKNewAuth must live in a writable directory — otherwise the
        // SDK's config create/update fails with EPERM before the SSO flow starts.
        // Persistence on tvOS goes through UserDefaults + IPC, not this file.
        return URL(fileURLWithPath: cacheDirectory()).appendingPathComponent(GlobalConstants.configFileName).path
        #else
        return getFilePath(fileName: GlobalConstants.configFileName)
        #endif
    }

    static func stateFile() -> String? {
        #if os(iOS)
        // Use profile-aware paths on iOS
        return ProfileManager.shared.activeStatePath()
        #elseif os(tvOS)
        // App Group container is not writable from the extension on tvOS.
        // The Go state manager writes temp files next to this path, so it must
        // live in a writable directory or every persist fails with EPERM.
        return URL(fileURLWithPath: cacheDirectory()).appendingPathComponent(GlobalConstants.stateFileName).path
        #else
        return getFilePath(fileName: GlobalConstants.stateFileName)
        #endif
    }

    /// Returns a writable directory for debug bundle ZIP generation.
    /// iOS: App Group container's Caches subdir. tvOS: process-local Caches.
    static func cacheDirectory() -> String {
        let fileManager = FileManager.default
        #if os(tvOS)
        if let cacheURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            do {
                try fileManager.createDirectory(at: cacheURL, withIntermediateDirectories: true)
                return cacheURL.path
            } catch {
                return fileManager.temporaryDirectory.path
            }
        }
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
    /// Note: On tvOS, app-group suites don't work at all — cfprefsd detaches
    /// ("Using kCFPreferencesAnyUser with a container is only allowed for System
    /// Containers") and every read returns nil. Use process-local standard defaults
    /// there; the app↔extension transfer happens via IPC instead.
    static func sharedUserDefaults() -> UserDefaults? {
        #if os(tvOS)
        return UserDefaults.standard
        #else
        return UserDefaults(suiteName: GlobalConstants.userPreferencesSuiteName)
        #endif
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

    // MARK: - Login Browser Account Tracking
    //
    // The login browser has one cookie jar shared by every profile. login_hint tells
    // the IdP which account a profile wants, but a hint is advisory — an IdP with a
    // live session for another account signs in with that session instead, which is
    // how a profile ends up holding a peer key and a token from two different
    // accounts. Recording which profile last completed a login through that jar lets
    // the next login of a different profile ask the IdP to re-decide, instead of
    // hoping the hint is honoured. Drift only ever costs one extra prompt, so nothing
    // depends on this being exact.

    /// Profile whose account the shared browser session last signed in with. Nil when
    /// no login has completed yet; "" when the session holds an account no profile may
    /// silently reuse (see `requireAccountSelectionOnNextLogin`).
    static func loadLastBrowserLoginProfile() -> String? {
        return sharedUserDefaults()?.string(forKey: GlobalConstants.keyLastBrowserLoginProfile)
    }

    /// Records the profile a completed login signed in as.
    static func saveLastBrowserLoginProfile(_ name: String) {
        sharedUserDefaults()?.set(name, forKey: GlobalConstants.keyLastBrowserLoginProfile)
    }

    /// Makes the next login — of any profile — ask the IdP to re-decide the account.
    /// Called on logout and on removing a profile: the browser session still holds the
    /// account that was just left, and no profile should be signed back into it
    /// silently. Stores "" because no profile can be named that, so the "profile
    /// changed" test below matches every profile.
    static func requireAccountSelectionOnNextLogin() {
        sharedUserDefaults()?.set("", forKey: GlobalConstants.keyLastBrowserLoginProfile)
    }

    /// Whether a login for `profile` must make the IdP re-decide which account signs
    /// in: the shared session last signed in as a different profile, or as an account
    /// that was logged out. The first login on an install has nothing to disambiguate.
    static func browserSessionHoldsAnotherProfile(_ profile: String) -> Bool {
        guard let last = loadLastBrowserLoginProfile() else { return false }
        return last != profile
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
