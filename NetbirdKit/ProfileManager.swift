//
//  ProfileManager.swift
//  NetBird
//
//  Native Swift implementation of multi-profile management.
//  Mirrors the Go ProfileManager logic: each profile is a subdirectory
//  containing its own netbird.cfg and state.json files.
//

import Foundation

// MARK: - Profile Model

struct Profile: Identifiable, Equatable {
    let name: String
    let isActive: Bool

    var id: String { name }

    static func == (lhs: Profile, rhs: Profile) -> Bool {
        lhs.name == rhs.name
    }
}

// MARK: - ProfileManager

/// Manages multiple VPN profiles, each with its own config/state files.
///
/// Directory layout inside the App Group container:
/// ```
/// profiles/
///   profiles.json          ← stores active profile name
///   default/
///     netbird.cfg
///     state.json
///   work/
///     netbird.cfg
///     state.json
/// ```
///
/// The "default" profile always exists. Legacy (pre-profile) config files
/// at the container root are migrated into `profiles/default/` on first use.
class ProfileManager {

    static let shared = ProfileManager()

    private let fileManager = FileManager.default

    /// Name validation: only letters, digits, underscore, hyphen (matches Go client).
    private static let validNamePattern = "^[a-zA-Z0-9_-]+$"

    private let defaultProfileName = "default"
    private let profilesDirName = "profiles"
    private let metaFileName = "profiles.json"

    // MARK: - Init

    private init() {
        ensureProfilesDirectory()
        migrateIfNeeded()
    }

    // MARK: - Public API

    /// Returns all profiles with their active status.
    func listProfiles() -> [Profile] {
        let meta = readMeta()
        let activeProfile = meta?.activeProfile.isEmpty == false ? meta!.activeProfile : defaultProfileName
        let deletedSet = Set(meta?.deletedProfiles ?? [])

        // Retry deletion of any directories still present after a previous attempt.
        for name in deletedSet {
            if let dir = profileDirectory(for: name), fileManager.fileExists(atPath: dir) {
                try? fileManager.removeItem(atPath: dir)
            }
        }

        guard let profilesDir = profilesDirectory() else { return [] }

        do {
            let contents = try fileManager.contentsOfDirectory(atPath: profilesDir)
            var profiles: [Profile] = []
            for name in contents.sorted() {
                guard !deletedSet.contains(name) else { continue }
                let fullPath = (profilesDir as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                if fileManager.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue {
                    profiles.append(Profile(name: name, isActive: name == activeProfile))
                }
            }
            // Ensure default always appears even if directory listing is empty
            if !profiles.contains(where: { $0.name == defaultProfileName }) {
                profiles.insert(Profile(name: defaultProfileName, isActive: defaultProfileName == activeProfile), at: 0)
            }
            return profiles
        } catch {
            AppLogger.shared.log("ProfileManager: Failed to list profiles: \(error)")
            return [Profile(name: defaultProfileName, isActive: true)]
        }
    }

    /// Name of the currently active profile.
    func getActiveProfileName() -> String {
        guard let meta = readMeta() else { return defaultProfileName }
        return meta.activeProfile.isEmpty ? defaultProfileName : meta.activeProfile
    }

    /// Adds a new profile. Throws if the name is invalid or already exists.
    func addProfile(_ name: String) throws {
        let sanitized = sanitizeName(name)
        guard isValidName(sanitized) else {
            throw ProfileError.invalidName(sanitized)
        }
        guard let dir = profileDirectory(for: sanitized) else {
            throw ProfileError.containerUnavailable
        }

        // If the profile was previously deleted but SDK goroutines recreated its directory,
        // remove the stale directory and tombstone so the profile can be created fresh.
        var meta = readMeta() ?? ProfileMeta(activeProfile: defaultProfileName)
        if meta.deletedProfiles.contains(sanitized) {
            try? fileManager.removeItem(atPath: dir)
            meta.deletedProfiles.removeAll { $0 == sanitized }
            try? writeMeta(meta)
        }

        guard !fileManager.fileExists(atPath: dir) else {
            throw ProfileError.alreadyExists(sanitized)
        }
        do {
            try fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            throw ProfileError.fileSystemError(error)
        }
    }

    /// Switches the active profile. The caller must stop VPN before calling this.
    func switchProfile(_ name: String) throws {
        guard let dir = profileDirectory(for: name), fileManager.fileExists(atPath: dir) else {
            throw ProfileError.notFound(name)
        }
        var meta = readMeta() ?? ProfileMeta(activeProfile: defaultProfileName)
        meta.activeProfile = name
        try writeMeta(meta)
    }

    /// Removes a profile. Cannot remove "default" or the currently active profile.
    func removeProfile(_ name: String) throws {
        guard name != defaultProfileName else {
            throw ProfileError.cannotRemoveDefault
        }
        guard name != getActiveProfileName() else {
            throw ProfileError.cannotRemoveActive
        }
        guard let dir = profileDirectory(for: name), fileManager.fileExists(atPath: dir) else {
            throw ProfileError.notFound(name)
        }

        // Persist the tombstone BEFORE deleting the directory.
        // The Go SDK may recreate the directory via background goroutines; the tombstone
        // ensures the profile stays hidden in listProfiles() even if that happens.
        var meta = readMeta() ?? ProfileMeta(activeProfile: defaultProfileName)
        if !meta.deletedProfiles.contains(name) {
            meta.deletedProfiles.append(name)
            try writeMeta(meta)
        }

        try fileManager.removeItem(atPath: dir)
    }

    /// Clears authentication data for a profile by removing its config and state files.
    /// Both files must be removed: state.json holds runtime state,
    /// netbird.cfg holds the auth tokens — removing only one is insufficient.
    func logoutProfile(_ name: String) throws {
        guard let dir = profileDirectory(for: name) else {
            throw ProfileError.containerUnavailable
        }
        let statePath  = (dir as NSString).appendingPathComponent(GlobalConstants.stateFileName)
        let configPath = (dir as NSString).appendingPathComponent(GlobalConstants.configFileName)
        if fileManager.fileExists(atPath: statePath) {
            try fileManager.removeItem(atPath: statePath)
        }
        if fileManager.fileExists(atPath: configPath) {
            try fileManager.removeItem(atPath: configPath)
        }
    }

    // MARK: - Path Accessors

    /// Config file path for the active profile.
    func activeConfigPath() -> String? {
        guard let dir = profileDirectory(for: getActiveProfileName()) else { return nil }
        return (dir as NSString).appendingPathComponent(GlobalConstants.configFileName)
    }

    /// State file path for the active profile.
    func activeStatePath() -> String? {
        guard let dir = profileDirectory(for: getActiveProfileName()) else { return nil }
        return (dir as NSString).appendingPathComponent(GlobalConstants.stateFileName)
    }

    /// Config file path for a specific profile.
    func configPath(for profile: String) -> String? {
        guard let dir = profileDirectory(for: profile) else { return nil }
        return (dir as NSString).appendingPathComponent(GlobalConstants.configFileName)
    }

    /// State file path for a specific profile.
    func statePath(for profile: String) -> String? {
        guard let dir = profileDirectory(for: profile) else { return nil }
        return (dir as NSString).appendingPathComponent(GlobalConstants.stateFileName)
    }

    /// Returns the management URL for a specific profile.
    /// Reads from netbird.cfg first; falls back to the ProfileConnectionCache
    /// so the URL remains visible even after logout (when the config is deleted).
    func managementURL(for profile: String) -> String? {
        if let cfgPath = configPath(for: profile),
           fileManager.fileExists(atPath: cfgPath),
           let data = fileManager.contents(atPath: cfgPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // ManagementURL can be a string or a nested object with Scheme/Host/Path
            var urlFromFile: String?
            if let urlString = json["ManagementURL"] as? String {
                urlFromFile = urlString
            } else if let urlObj = json["ManagementURL"] as? [String: Any],
                      let scheme = urlObj["Scheme"] as? String,
                      let host = urlObj["Host"] as? String {
                let path = urlObj["Path"] as? String ?? ""
                urlFromFile = "\(scheme)://\(host)\(path)"
            }
            if let url = urlFromFile {
                // Keep cache in sync so it's available after logout
                ProfileConnectionCache().saveManagementURL(url, for: profile)
                return url
            }
        }
        // Config missing (e.g. after logout) — return cached value
        return ProfileConnectionCache().managementURL(for: profile)
    }

    // MARK: - Private Helpers

    private func containerURL() -> URL? {
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: GlobalConstants.userPreferencesSuiteName)
    }

    private func profilesDirectory() -> String? {
        guard let container = containerURL() else { return nil }
        return container.appendingPathComponent(profilesDirName).path
    }

    private func profileDirectory(for name: String) -> String? {
        guard let profilesDir = profilesDirectory() else { return nil }
        return (profilesDir as NSString).appendingPathComponent(name)
    }

    private func metaFilePath() -> String? {
        guard let profilesDir = profilesDirectory() else { return nil }
        return (profilesDir as NSString).appendingPathComponent(metaFileName)
    }

    private func ensureProfilesDirectory() {
        guard let profilesDir = profilesDirectory() else { return }
        if !fileManager.fileExists(atPath: profilesDir) {
            try? fileManager.createDirectory(atPath: profilesDir, withIntermediateDirectories: true)
        }
        // Ensure default profile directory exists
        guard let defaultDir = profileDirectory(for: defaultProfileName) else { return }
        if !fileManager.fileExists(atPath: defaultDir) {
            try? fileManager.createDirectory(atPath: defaultDir, withIntermediateDirectories: true)
        }
    }

    /// Migrates legacy config/state from the container root into profiles/default/.
    private func migrateIfNeeded() {
        guard let container = containerURL() else { return }
        guard let defaultDir = profileDirectory(for: defaultProfileName) else { return }

        let legacyConfig = container.appendingPathComponent(GlobalConstants.configFileName).path
        let legacyState = container.appendingPathComponent(GlobalConstants.stateFileName).path
        let newConfig = (defaultDir as NSString).appendingPathComponent(GlobalConstants.configFileName)
        let newState = (defaultDir as NSString).appendingPathComponent(GlobalConstants.stateFileName)

        // Only migrate if legacy files exist and new ones don't
        if fileManager.fileExists(atPath: legacyConfig) && !fileManager.fileExists(atPath: newConfig) {
            try? fileManager.copyItem(atPath: legacyConfig, toPath: newConfig)
            AppLogger.shared.log("ProfileManager: Migrated legacy config to default profile")
        }
        if fileManager.fileExists(atPath: legacyState) && !fileManager.fileExists(atPath: newState) {
            try? fileManager.copyItem(atPath: legacyState, toPath: newState)
            AppLogger.shared.log("ProfileManager: Migrated legacy state to default profile")
        }

        // Set default as active if no meta exists
        if readMeta() == nil {
            try? writeMeta(ProfileMeta(activeProfile: defaultProfileName))
        }
    }

    private func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.range(of: ProfileManager.validNamePattern, options: .regularExpression) != nil
    }

    private func sanitizeName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        return String(name.unicodeScalars.filter { allowed.contains($0) })
    }

    // MARK: - Meta File (profiles.json)

    private struct ProfileMeta: Codable {
        var activeProfile: String
        /// Profiles pending deletion — kept as a tombstone so that directories
        /// recreated by SDK background goroutines don't reappear in the list.
        var deletedProfiles: [String]

        init(activeProfile: String, deletedProfiles: [String] = []) {
            self.activeProfile = activeProfile
            self.deletedProfiles = deletedProfiles
        }

        /// Backward-compatible decode: old profiles.json files have no deletedProfiles field.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            activeProfile = try c.decode(String.self, forKey: .activeProfile)
            deletedProfiles = (try? c.decode([String].self, forKey: .deletedProfiles)) ?? []
        }
    }

    private func readMeta() -> ProfileMeta? {
        guard let path = metaFilePath(),
              let data = fileManager.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(ProfileMeta.self, from: data)
    }

    private func writeMeta(_ meta: ProfileMeta) throws {
        guard let path = metaFilePath() else {
            throw ProfileError.containerUnavailable
        }
        let data = try JSONEncoder().encode(meta)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

// MARK: - Errors

enum ProfileError: LocalizedError {
    case invalidName(String)
    case alreadyExists(String)
    case notFound(String)
    case cannotRemoveDefault
    case cannotRemoveActive
    case containerUnavailable
    case fileSystemError(Error)

    var errorDescription: String? {
        switch self {
        case .invalidName(let name):
            return "Invalid profile name: '\(name)'. Only letters, numbers, underscores and hyphens are allowed."
        case .alreadyExists(let name):
            return "Profile '\(name)' already exists."
        case .notFound(let name):
            return "Profile '\(name)' not found."
        case .cannotRemoveDefault:
            return "Cannot remove the default profile."
        case .cannotRemoveActive:
            return "Cannot remove the active profile. Switch to another profile first."
        case .containerUnavailable:
            return "App group container is unavailable."
        case .fileSystemError(let error):
            return "File system error: \(error.localizedDescription)"
        }
    }
}
