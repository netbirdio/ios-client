//
//  ProfileConnectionCache.swift
//  NetBird
//

import Foundation

// MARK: - Model

struct ProfileConnectionEntry: Codable, Equatable {
    var ip: String
    var fqdn: String
    var managementURL: String?
}

// MARK: - Cache

/// Stores and retrieves last-known connection data (ip/fqdn/managementURL) per profile.
/// Persisted as a JSON-encoded dictionary under a single UserDefaults key.
struct ProfileConnectionCache {

    private static let storageKey = "netbird_profiles_connection_data"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Read

    func entry(for profile: String) -> ProfileConnectionEntry? {
        return load()[profile]
    }

    func managementURL(for profile: String) -> String? {
        return load()[profile]?.managementURL
    }

    // MARK: - Write

    func save(ip: String, fqdn: String, for profile: String) {
        var all = load()
        var entry = all[profile] ?? ProfileConnectionEntry(ip: "", fqdn: "", managementURL: nil)
        entry.ip = ip
        entry.fqdn = fqdn
        all[profile] = entry
        persist(all)
    }

    func saveManagementURL(_ url: String, for profile: String) {
        var all = load()
        var entry = all[profile] ?? ProfileConnectionEntry(ip: "", fqdn: "", managementURL: nil)
        entry.managementURL = url
        all[profile] = entry
        persist(all)
    }

    /// Clears ip/fqdn for a profile after logout, preserving managementURL for re-login.
    func clearConnectionData(for profile: String) {
        var all = load()
        guard var entry = all[profile] else { return }
        entry.ip = ""
        entry.fqdn = ""
        all[profile] = entry
        persist(all)
    }

    /// Removes all cached data for a deleted profile.
    func remove(for profile: String) {
        var all = load()
        guard all[profile] != nil else { return }
        all.removeValue(forKey: profile)
        persist(all)
    }

    // MARK: - Private

    private func load() -> [String: ProfileConnectionEntry] {
        guard
            let data = defaults.data(forKey: Self.storageKey),
            let decoded = try? JSONDecoder().decode([String: ProfileConnectionEntry].self, from: data)
        else { return [:] }
        return decoded
    }

    private func persist(_ entries: [String: ProfileConnectionEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
