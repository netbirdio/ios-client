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
///
/// Backed by the App Group suite so the main app and the network extension see
/// the same entries: the extension is the process that learns the peer's ip/fqdn
/// and, on iOS, runs its own login.
///
/// Each profile is stored under two keys — one for the connection data
/// (ip/fqdn/ipv6, always written together by the status updates) and one for
/// the management URL (written by the login paths). The split matches the
/// write patterns, so every write is a blind single-key set with no
/// read-modify-write: concurrent writers in the two processes cannot clobber
/// each other's fields, and no cross-process locking is needed (file
/// coordination is unsafe from an extension — the other process can be
/// suspended while holding a claim).
struct ProfileConnectionCache {

    private static let legacyStorageKey = "netbird_profiles_connection_data"
    private static let connectionKeyPrefix = "netbird_profile_connection_"
    private static let managementURLKeyPrefix = "netbird_profile_mgmt_url_"

    private struct ConnectionData: Codable, Equatable {
        var ip: String
        var fqdn: String
        var ipv6: String?
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults? = nil) {
        let store = defaults ?? Preferences.sharedUserDefaults() ?? .standard
        ProfileConnectionCache.migrateFromStandardIfNeeded(into: store)
        ProfileConnectionCache.migrateBlobToPerProfileKeysIfNeeded(in: store)
        self.defaults = store
    }

    // MARK: - Read

    func entry(forID id: String) -> ProfileConnectionEntry? {
        let connection = Self.connectionData(forID: id, in: defaults)
        let url = defaults.string(forKey: Self.managementURLKey(id))
        guard connection != nil || url != nil else { return nil }
        return ProfileConnectionEntry(ip: connection?.ip ?? "",
                                      fqdn: connection?.fqdn ?? "",
                                      managementURL: url,
                                      ipv6: connection?.ipv6)
    }

    func managementURL(forID id: String) -> String? {
        return defaults.string(forKey: Self.managementURLKey(id))
    }

    // MARK: - Write

    func save(ip: String, fqdn: String, ipv6: String? = nil, forID id: String) {
        guard let data = try? JSONEncoder().encode(ConnectionData(ip: ip, fqdn: fqdn, ipv6: ipv6)) else { return }
        defaults.set(data, forKey: Self.connectionKey(id))
    }

    func saveManagementURL(_ url: String, forID id: String) {
        defaults.set(url, forKey: Self.managementURLKey(id))
    }

    /// Clears ip/fqdn for a profile after logout, preserving managementURL for re-login.
    func clearConnectionData(forID id: String) {
        defaults.removeObject(forKey: Self.connectionKey(id))
    }

    /// Removes all cached data for a deleted profile.
    func remove(forID id: String) {
        defaults.removeObject(forKey: Self.connectionKey(id))
        defaults.removeObject(forKey: Self.managementURLKey(id))
    }

    // MARK: - Private

    private static func connectionKey(_ id: String) -> String {
        return connectionKeyPrefix + id
    }

    private static func managementURLKey(_ id: String) -> String {
        return managementURLKeyPrefix + id
    }

    private static func connectionData(forID id: String, in store: UserDefaults) -> ConnectionData? {
        guard let data = store.data(forKey: connectionKey(id)) else { return nil }
        return try? JSONDecoder().decode(ConnectionData.self, from: data)
    }

    /// Merges the single-blob cache written by an earlier app version into the
    /// App Group suite's blob, which migrateBlobToPerProfileKeysIfNeeded then
    /// explodes into the per-profile keys. Suite values win field by field —
    /// the suite is strictly newer than the legacy copy, which is frozen at
    /// upgrade time — and legacy values only fill fields the suite holds no
    /// value for (e.g. ip/fqdn on an entry the extension seeded with just the
    /// URL before the app first ran). The standard-domain copy is removed only
    /// after a verified read-back of the merged data, so a write that silently
    /// fails (e.g. missing App Group entitlement) cannot destroy the last
    /// remaining copy; the migration then retries on the next init.
    static func migrateFromStandardIfNeeded(from standard: UserDefaults = .standard, into store: UserDefaults) {
        guard store != standard else { return }
        guard let legacyData = standard.data(forKey: legacyStorageKey) else { return }

        let decoder = JSONDecoder()
        let legacy = (try? decoder.decode([String: ProfileConnectionEntry].self, from: legacyData)) ?? [:]
        let suite = store.data(forKey: legacyStorageKey)
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
        store.set(mergedData, forKey: legacyStorageKey)

        guard let readBack = store.data(forKey: legacyStorageKey),
              (try? decoder.decode([String: ProfileConnectionEntry].self, from: readBack)) == merged
        else { return }
        standard.removeObject(forKey: legacyStorageKey)
    }

    /// Explodes the single-blob layout into the per-profile keys. Existing keys
    /// are never overwritten — they are strictly newer than the blob — so two
    /// processes migrating concurrently stay benign. The blob is removed only
    /// after a verified read-back of every entry, so a write that silently
    /// fails leaves the blob in place and the migration retries on the next
    /// init.
    static func migrateBlobToPerProfileKeysIfNeeded(in store: UserDefaults) {
        guard let blobData = store.data(forKey: legacyStorageKey) else { return }
        let decoder = JSONDecoder()
        let entries = (try? decoder.decode([String: ProfileConnectionEntry].self, from: blobData)) ?? [:]

        for (id, entry) in entries {
            if store.data(forKey: connectionKey(id)) == nil,
               let data = try? JSONEncoder().encode(ConnectionData(ip: entry.ip, fqdn: entry.fqdn, ipv6: entry.ipv6)) {
                store.set(data, forKey: connectionKey(id))
            }
            if store.string(forKey: managementURLKey(id)) == nil,
               let url = entry.managementURL, !url.isEmpty {
                store.set(url, forKey: managementURLKey(id))
            }
        }

        let landed = entries.allSatisfy { id, entry in
            let connectionLanded = connectionData(forID: id, in: store) != nil
            let urlLanded = entry.managementURL?.isEmpty != false
                || store.string(forKey: managementURLKey(id)) != nil
            return connectionLanded && urlLanded
        }
        guard landed else { return }
        store.removeObject(forKey: legacyStorageKey)
    }
}
