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
/// Keyed by profile ID. Persisted as a JSON-encoded dictionary under a single UserDefaults key.
struct ProfileConnectionCache {

    private static let storageKey = "netbird_profiles_connection_data"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Read

    func entry(forID id: String) -> ProfileConnectionEntry? {
        return load()[id]
    }

    func managementURL(forID id: String) -> String? {
        return load()[id]?.managementURL
    }

    // MARK: - Write

    func save(ip: String, fqdn: String, forID id: String) {
        var all = load()
        var entry = all[id] ?? ProfileConnectionEntry(ip: "", fqdn: "", managementURL: nil)
        entry.ip = ip
        entry.fqdn = fqdn
        all[id] = entry
        persist(all)
    }

    func saveManagementURL(_ url: String, forID id: String) {
        var all = load()
        var entry = all[id] ?? ProfileConnectionEntry(ip: "", fqdn: "", managementURL: nil)
        entry.managementURL = url
        all[id] = entry
        persist(all)
    }

    /// Clears ip/fqdn for a profile after logout, preserving managementURL for re-login.
    func clearConnectionData(forID id: String) {
        var all = load()
        guard var entry = all[id] else { return }
        entry.ip = ""
        entry.fqdn = ""
        all[id] = entry
        persist(all)
    }

    /// Removes all cached data for a deleted profile.
    func remove(forID id: String) {
        var all = load()
        guard all[id] != nil else { return }
        all.removeValue(forKey: id)
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
