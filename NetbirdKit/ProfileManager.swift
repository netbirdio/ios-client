//
//  ProfileManager.swift
//  NetBird
//
//  Thin Swift wrapper over the Go (gomobile) profile manager.
//  Profile identity is ID-based: the on-disk filename is the profile ID and
//  the human-readable name lives inside the profile config. All profile state
//  (which profile is active, config/state paths, add/remove/logout/rename) is
//  owned by netbird-core's profilemanager.ServiceManager via NetBirdSDK — this
//  is the same split Android uses, where the native side only drives the VPN
//  lifecycle.
//
//  tvOS does not expose a multi-profile UI and routes its config through the
//  container root (see Preferences), so on tvOS this type degrades to a single
//  "default" profile and never touches the Go profile manager.
//

import Foundation
import NetBirdSDK

// MARK: - Profile Model

struct Profile: Identifiable, Equatable {
    /// On-disk filename stem. A 32-char hex string for profiles created after
    /// the ID migration, or the legacy name for migrated profiles. The
    /// reserved value "default" identifies the default profile.
    let id: String
    /// Human-readable display name.
    let name: String
    let isActive: Bool

    var isDefault: Bool { id == ProfileManager.defaultProfileID }

    static func == (lhs: Profile, rhs: Profile) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - ProfileManager

class ProfileManager {

    static let shared = ProfileManager()

    /// Reserved ID of the always-present default profile (matches
    /// profilemanager.DefaultProfileName in netbird-core).
    static let defaultProfileID = "default"

    private let fileManager = FileManager.default

    // MARK: - Init

#if os(iOS)
    private let go: NetBirdSDKProfileManager

    private init() {
        let configDir = ProfileManager.containerBasePath()
        // The one-time migration from the legacy directory-per-name layout must
        // run BEFORE the Go manager reads or creates anything.
        ProfileLayoutMigration.runIfNeeded(configDir: configDir)
        guard let manager = NetBirdSDKNewProfileManager(configDir) else {
            preconditionFailure("Failed to create NetBirdSDKProfileManager at \(configDir)")
        }
        self.go = manager
        ProfileManager.excludeProfileStorageFromBackup(configDir: configDir)
    }
#else
    private init() {}
#endif

    // MARK: - Public API (platform-shared signatures)

    /// Returns all profiles with their active status.
    func listProfiles() -> [Profile] {
#if os(iOS)
        do {
            // gomobile maps (*ProfileArray, error) to a non-optional throwing call.
            let array = try go.listProfiles()
            var profiles: [Profile] = []
            for i in 0..<array.length() {
                if let p = array.get(i) {
                    profiles.append(Profile(id: p.id_, name: p.name, isActive: p.isActive))
                }
            }
            return profiles.isEmpty ? [ProfileManager.fallbackDefault()] : profiles
        } catch {
            AppLogger.shared.log("ProfileManager.listProfiles failed: \(error)")
            return [ProfileManager.fallbackDefault()]
        }
#else
        return [ProfileManager.fallbackDefault()]
#endif
    }

    /// The currently active profile, or nil if it cannot be resolved.
    func activeProfile() -> Profile? {
#if os(iOS)
        guard let p = try? go.getActiveProfile() else { return nil }
        return Profile(id: p.id_, name: p.name, isActive: true)
#else
        return ProfileManager.fallbackDefault()
#endif
    }

    /// Display name of the active profile (for UI). Falls back to "default".
    func getActiveProfileName() -> String {
        activeProfile()?.name ?? ProfileManager.defaultProfileID
    }

    /// ID of the active profile (for paths and the connection cache).
    func getActiveProfileID() -> String {
        activeProfile()?.id ?? ProfileManager.defaultProfileID
    }

    // MARK: - Path Accessors

    /// Config file path for the active profile.
    func activeConfigPath() -> String? {
#if os(iOS)
        return goPath { go.getActiveConfigPath($0) }
#else
        return Preferences.getFilePath(fileName: GlobalConstants.configFileName)
#endif
    }

    /// State file path for the active profile.
    func activeStatePath() -> String? {
#if os(iOS)
        return goPath { go.getActiveStateFilePath($0) }
#else
        return Preferences.getFilePath(fileName: GlobalConstants.stateFileName)
#endif
    }

    /// Config file path for a specific profile ID.
    func configPath(forID id: String) -> String? {
#if os(iOS)
        return goPath { go.getConfigPath(id, error: $0) }
#else
        return Preferences.getFilePath(fileName: GlobalConstants.configFileName)
#endif
    }

    /// State file path for a specific profile ID.
    func statePath(forID id: String) -> String? {
#if os(iOS)
        return goPath { go.getStateFilePath(id, error: $0) }
#else
        return Preferences.getFilePath(fileName: GlobalConstants.stateFileName)
#endif
    }

    // MARK: - Management URL

    /// Returns the management URL for a profile, read from the profile config
    /// and falling back to the connection cache.
    ///
    /// The config is the source of truth: in the ID-based layout it survives
    /// logout (only the keys are cleared), and the core merges into it rather
    /// than rebuilding it, so the URL cannot be dropped by a write. The cache
    /// covers the window where the config is not readable yet — it lives in the
    /// App Group suite, so the extension sees what the app wrote.
    func managementURL(forID id: String) -> String? {
        if let cfgPath = configPath(forID: id),
           fileManager.fileExists(atPath: cfgPath),
           let url = ProfileManager.readManagementURL(fromConfigAt: cfgPath) {
            ProfileConnectionCache().saveManagementURL(url, forID: id)
            return url
        }
        return ProfileConnectionCache().managementURL(forID: id)
    }

    /// Records the management URL for a profile so it is available before the
    /// profile config can be read back.
    func saveServerURL(_ url: String, forID id: String) {
        ProfileConnectionCache().saveManagementURL(url, forID: id)
    }

#if os(iOS)
    // MARK: - Mutating Operations (iOS only — profiles UI is iOS only)

    /// Adds a new profile and returns it. The returned profile carries the
    /// freshly generated ID, which callers must use for all follow-up
    /// operations (the ID is NOT the display name).
    @discardableResult
    func addProfile(_ name: String) throws -> Profile {
        // gomobile maps (*Profile, error) to a non-optional throwing call: a
        // failure surfaces as a thrown error, not a nil return.
        let p = try go.addProfile(name)
        return Profile(id: p.id_, name: p.name, isActive: false)
    }

    /// Switches the active profile. The caller must stop the VPN before calling.
    func switchProfile(id: String) throws {
        try go.switchProfile(id)
    }

    /// Renames a profile's display name. The on-disk ID is unchanged.
    func renameProfile(id: String, to newName: String) throws {
        try go.renameProfile(id, newName: newName)
    }

    /// Removes a profile. Cannot remove the default or the active profile.
    func removeProfile(id: String) throws {
        try go.removeProfile(id)
        ProfileConnectionCache().remove(forID: id)
    }

    /// Clears authentication for a profile, forcing re-login. The management
    /// URL is preserved (it stays in the config).
    func logoutProfile(id: String) throws {
        try go.logoutProfile(id)
        ProfileConnectionCache().clearConnectionData(forID: id)
    }
#endif

    // MARK: - Helpers

    private static func fallbackDefault() -> Profile {
        Profile(id: defaultProfileID, name: defaultProfileID, isActive: true)
    }

    /// Parses the management URL from a profile config file. The Go SDK may
    /// serialize ManagementURL either as a plain string or as a nested object
    /// with Scheme/Host/Path.
    static func readManagementURL(fromConfigAt path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let urlString = json["ManagementURL"] as? String, !urlString.isEmpty {
            return urlString
        }
        if let urlObj = json["ManagementURL"] as? [String: Any],
           let scheme = urlObj["Scheme"] as? String,
           let host = urlObj["Host"] as? String {
            let urlPath = urlObj["Path"] as? String ?? ""
            return "\(scheme)://\(host)\(urlPath)"
        }
        return nil
    }

#if os(iOS)
    /// Wraps a gomobile path getter. gomobile exposes its non-null String
    /// returns as a value plus an explicit NSErrorPointer parameter (not a
    /// throwing call), returning "" and setting the error on failure.
    private func goPath(_ call: (NSErrorPointer) -> String) -> String? {
        var err: NSError?
        let result = call(&err)
        if let err {
            AppLogger.shared.log("ProfileManager: path resolution failed: \(err.localizedDescription)")
            return nil
        }
        return result.isEmpty ? nil : result
    }

    /// Excludes the profile storage from iCloud/iTunes backups. The profile
    /// configs hold the WireGuard and SSH private keys, and the WireGuard key
    /// is the peer's identity: restoring a backup onto another device would
    /// produce two peers with the same key. Re-applied on every launch because
    /// the Go core replaces some of these files atomically (temp + rename),
    /// which drops per-file attributes; the profiles/ directory is excluded as
    /// a whole so its contents stay covered regardless. The directory is
    /// created here if missing so the exclusion is in place before the Go
    /// manager first writes into it.
    private static func excludeProfileStorageFromBackup(configDir: String) {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: configDir, isDirectory: true)

        let profilesDir = root.appendingPathComponent("profiles", isDirectory: true)
        try? fm.createDirectory(at: profilesDir, withIntermediateDirectories: true)
        excludeFromBackup(profilesDir)

        // serverURLFileName is no longer written, but earlier versions left one
        // behind; keep excluding it until the leftovers are cleaned up.
        let rootFiles = [
            GlobalConstants.configFileName,
            GlobalConstants.stateFileName,
            GlobalConstants.serverURLFileName,
            "active_profile.json",
        ]
        for name in rootFiles {
            let file = root.appendingPathComponent(name)
            guard fm.fileExists(atPath: file.path) else { continue }
            excludeFromBackup(file)
        }
    }

    private static func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try url.setResourceValues(values)
        } catch {
            AppLogger.shared.log("ProfileManager: backup exclusion failed for \(url.lastPathComponent): \(error)")
        }
    }

    /// Base directory for profile storage: the App Group shared container.
    private static func containerBasePath() -> String {
        let fm = FileManager.default
        if let groupURL = fm.containerURL(forSecurityApplicationGroupIdentifier: GlobalConstants.userPreferencesSuiteName) {
            return groupURL.path
        }
        #if DEBUG
        let baseURL = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.urls(for: .documentDirectory, in: .userDomainMask).first
        return (baseURL ?? fm.temporaryDirectory).path
        #else
        AppLogger.shared.log("ERROR: App group '\(GlobalConstants.userPreferencesSuiteName)' unavailable; profiles degraded.")
        return fm.temporaryDirectory.path
        #endif
    }
#endif
}
