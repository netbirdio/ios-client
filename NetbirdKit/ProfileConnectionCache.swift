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

    /// Merges entries written by an earlier app version into the App Group suite.
    /// Suite values win field by field — the suite is strictly newer than the
    /// legacy copy, which is frozen at upgrade time — and legacy values only fill
    /// fields the suite holds no value for (e.g. ip/fqdn on an entry the
    /// extension seeded with just the URL before the app first ran). The
    /// standard-domain copy is removed only after a verified read-back of the
    /// merged data, so a write that silently fails (e.g. missing App Group
    /// entitlement) cannot destroy the last remaining copy; the migration then
    /// retries on the next init.
    static func migrateFromStandardIfNeeded(from standard: UserDefaults = .standard, into store: UserDefaults) {
        guard store != standard else { return }
        guard let legacyData = standard.data(forKey: storageKey) else { return }

        let decoder = JSONDecoder()
        let legacy = (try? decoder.decode([String: ProfileConnectionEntry].self, from: legacyData)) ?? [:]
        let suite = store.data(forKey: storageKey)
            .flatMap { try? decoder.decode([String: ProfileConnectionEntry].self, from: $0) } ?? [:]

        var merged = suite
        for (id, legacyEntry) in legacy {
            if var entry = merged[id] {
                if entry.ip.isEmpty { entry.ip = legacyEntry.ip }
                if entry.fqdn.isEmpty { entry.fqdn = legacyEntry.fqdn }
                if entry.managementURL?.isEmpty != false { entry.managementURL = legacyEntry.managementURL }
                if entry.ipv6?.isEmpty != false { entry.ipv6 = legacyEntry.ipv6 }
                merged[id] = entry
            } else {
                merged[id] = legacyEntry
            }
        }

        guard let mergedData = try? JSONEncoder().encode(merged) else { return }
        store.set(mergedData, forKey: storageKey)

        guard let readBack = store.data(forKey: storageKey),
              (try? decoder.decode([String: ProfileConnectionEntry].self, from: readBack)) == merged
        else { return }
        standard.removeObject(forKey: storageKey)
    }
}
