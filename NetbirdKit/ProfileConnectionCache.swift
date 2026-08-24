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
    var ipv6: String?
}

// MARK: - Cache

/// Stores and retrieves last-known connection data (ip/fqdn/managementURL) per profile.
/// Keyed by profile ID. Persisted as a JSON-encoded dictionary under a single UserDefaults key.
///
/// Backed by the App Group suite so the main app and the network extension see
/// the same entries: the extension is the process that learns the peer's ip/fqdn
/// and, on iOS, runs its own login. With the previous `.standard` backing each
/// process kept its own copy, so a value written by one was invisible to the
/// other.
struct ProfileConnectionCache {

    private static let storageKey = "netbird_profiles_connection_data"
    private let defaults: UserDefaults

    init(defaults: UserDefaults? = nil) {
        let store = defaults ?? Preferences.sharedUserDefaults() ?? .standard
        ProfileConnectionCache.migrateFromStandardIfNeeded(into: store)
        self.defaults = store
    }

    // MARK: - Read

    func entry(forID id: String) -> ProfileConnectionEntry? {
        return load()[id]
    }

    func managementURL(forID id: String) -> String? {
        return load()[id]?.managementURL
    }

    // MARK: - Write

    func save(ip: String, fqdn: String, ipv6: String? = nil, forID id: String) {
        var all = load()
        var entry = all[id] ?? ProfileConnectionEntry(ip: "", fqdn: "", managementURL: nil, ipv6: nil)
        entry.ip = ip
        entry.fqdn = fqdn
        entry.ipv6 = ipv6
        all[id] = entry
        persist(all)
    }

    func saveManagementURL(_ url: String, forID id: String) {
        var all = load()
        var entry = all[id] ?? ProfileConnectionEntry(ip: "", fqdn: "", managementURL: nil, ipv6: nil)
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
        entry.ipv6 = nil
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

    /// Moves entries written by an earlier app version into the App Group suite.
    /// The standard-domain copy is removed afterwards, and a suite that already
    /// holds data is never overwritten, so entries the extension has since
    /// written cannot be clobbered by a stale app-local copy.
    private static func migrateFromStandardIfNeeded(into store: UserDefaults) {
        guard store != .standard else { return }

        let standard = UserDefaults.standard
        guard let legacy = standard.data(forKey: storageKey) else { return }

        if store.data(forKey: storageKey) == nil {
            store.set(legacy, forKey: storageKey)
        }
        standard.removeObject(forKey: storageKey)
    }
}
