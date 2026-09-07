//
//  ProfileConnectionCacheTests.swift
//  NetBirdTests
//
//  Verifies the profile connection cache's migrations and write semantics:
//
//  - standard → App Group suite blob merge: legacy entries are merged field by
//    field (suite values win, legacy fills the gaps), and the standard-domain
//    copy is removed only after a verified read-back — a suite write that
//    silently fails must not destroy the last remaining copy.
//  - blob → per-profile keys: the single JSON blob is exploded into one
//    connection-data key and one management-URL key per profile; existing keys
//    are never overwritten, and the blob is removed only after every entry
//    verifiably landed.
//  - per-key writes: each write path touches its own key blindly, so writers
//    in the two processes cannot clobber each other's fields.
//
//  The migration source and target are injected as plain named suites, so
//  these tests do not touch the real standard domain or the App Group.
//

import XCTest
@testable import NetBird

final class ProfileConnectionCacheTests: XCTestCase {

    private static let blobKey = "netbird_profiles_connection_data"

    private var sourceName: String!
    private var targetName: String!
    private var source: UserDefaults!
    private var target: UserDefaults!

    override func setUpWithError() throws {
        sourceName = "nb-cache-test-source-\(UUID().uuidString)"
        targetName = "nb-cache-test-target-\(UUID().uuidString)"
        source = try XCTUnwrap(UserDefaults(suiteName: sourceName))
        target = try XCTUnwrap(UserDefaults(suiteName: targetName))
    }

    override func tearDownWithError() throws {
        source?.removePersistentDomain(forName: sourceName)
        target?.removePersistentDomain(forName: targetName)
        source = nil
        target = nil
    }

    // MARK: - Helpers

    private func migrate() {
        ProfileConnectionCache.migrateFromStandardIfNeeded(from: source, into: target)
    }

    private func writeBlob(_ entries: [String: ProfileConnectionEntry], to defaults: UserDefaults) throws {
        defaults.set(try JSONEncoder().encode(entries), forKey: Self.blobKey)
    }

    private func readBlob(_ defaults: UserDefaults) throws -> [String: ProfileConnectionEntry]? {
        guard let data = defaults.data(forKey: Self.blobKey) else { return nil }
        return try JSONDecoder().decode([String: ProfileConnectionEntry].self, from: data)
    }

    private func entry(ip: String = "", fqdn: String = "",
                       url: String? = nil, ipv6: String? = nil) -> ProfileConnectionEntry {
        return ProfileConnectionEntry(ip: ip, fqdn: fqdn, managementURL: url, ipv6: ipv6)
    }

    // MARK: - Standard → suite blob merge

    func testMovesLegacyIntoEmptySuite() throws {
        try writeBlob(["a": entry(ip: "100.1.1.1", fqdn: "a.netbird.cloud",
                                  url: "https://mgmt.example.com:443")], to: source)

        migrate()

        let migrated = try XCTUnwrap(try readBlob(target))
        XCTAssertEqual(migrated["a"], entry(ip: "100.1.1.1", fqdn: "a.netbird.cloud",
                                            url: "https://mgmt.example.com:443"))
        XCTAssertNil(source.data(forKey: Self.blobKey))
    }

    func testMergesLegacyProfileMissingFromSuite() throws {
        try writeBlob(["a": entry(url: "https://suite.example.com")], to: target)
        try writeBlob(["b": entry(ip: "100.2.2.2", fqdn: "b.netbird.cloud")], to: source)

        migrate()

        let merged = try XCTUnwrap(try readBlob(target))
        XCTAssertEqual(merged["a"], entry(url: "https://suite.example.com"))
        XCTAssertEqual(merged["b"], entry(ip: "100.2.2.2", fqdn: "b.netbird.cloud"))
        XCTAssertNil(source.data(forKey: Self.blobKey))
    }

    func testFillsEmptyFieldsFromLegacy() throws {
        // The extension seeds URL-only entries before the app first runs after
        // the upgrade (on-demand VPN): the legacy ip/fqdn must survive the merge.
        try writeBlob(["a": entry(url: "https://suite.example.com")], to: target)
        try writeBlob(["a": entry(ip: "100.1.1.1", fqdn: "a.netbird.cloud",
                                  url: "https://legacy.example.com", ipv6: "fd00::1")], to: source)

        migrate()

        let merged = try XCTUnwrap(try readBlob(target))
        XCTAssertEqual(merged["a"], entry(ip: "100.1.1.1", fqdn: "a.netbird.cloud",
                                          url: "https://suite.example.com", ipv6: "fd00::1"))
    }

    func testSuiteValuesWinOnConflict() throws {
        try writeBlob(["a": entry(ip: "100.9.9.9", fqdn: "new.netbird.cloud",
                                  url: "https://suite.example.com")], to: target)
        try writeBlob(["a": entry(ip: "100.1.1.1", fqdn: "old.netbird.cloud",
                                  url: "https://legacy.example.com")], to: source)

        migrate()

        let merged = try XCTUnwrap(try readBlob(target))
        XCTAssertEqual(merged["a"], entry(ip: "100.9.9.9", fqdn: "new.netbird.cloud",
                                          url: "https://suite.example.com"))
    }

    func testKeepsLegacyWhenSuiteWriteDoesNotPersist() throws {
        try writeBlob(["a": entry(ip: "100.1.1.1", fqdn: "a.netbird.cloud")], to: source)
        let dropping = try XCTUnwrap(
            WriteDroppingDefaults(suiteName: "nb-cache-test-dropping-\(UUID().uuidString)"))

        ProfileConnectionCache.migrateFromStandardIfNeeded(from: source, into: dropping)

        XCTAssertNotNil(source.data(forKey: Self.blobKey))
    }

    func testRemovesUndecodableLegacyBlob() throws {
        source.set(Data("not json".utf8), forKey: Self.blobKey)
        try writeBlob(["a": entry(url: "https://suite.example.com")], to: target)

        migrate()

        XCTAssertNil(source.data(forKey: Self.blobKey))
        let kept = try XCTUnwrap(try readBlob(target))
        XCTAssertEqual(kept["a"], entry(url: "https://suite.example.com"))
    }

    func testNoopWhenTargetIsSource() throws {
        try writeBlob(["a": entry(ip: "100.1.1.1", fqdn: "a.netbird.cloud")], to: source)

        ProfileConnectionCache.migrateFromStandardIfNeeded(from: source, into: source)

        XCTAssertNotNil(source.data(forKey: Self.blobKey))
    }

    func testMergeIsIdempotent() throws {
        try writeBlob(["a": entry(url: "https://suite.example.com")], to: target)
        try writeBlob(["b": entry(ip: "100.2.2.2", fqdn: "b.netbird.cloud")], to: source)

        migrate()
        let first = try readBlob(target)
        migrate()

        XCTAssertEqual(try readBlob(target), first)
    }

    // MARK: - Blob → per-profile keys migration

    func testExplodesBlobIntoPerProfileKeys() throws {
        try writeBlob(["a": entry(ip: "100.1.1.1", fqdn: "a.netbird.cloud",
                                  url: "https://mgmt.example.com", ipv6: "fd00::1"),
                       "b": entry(url: "https://b.example.com")], to: target)

        ProfileConnectionCache.migrateBlobToPerProfileKeysIfNeeded(in: target)

        XCTAssertNil(target.data(forKey: Self.blobKey))
        let cache = ProfileConnectionCache(defaults: target)
        XCTAssertEqual(cache.entry(forID: "a"), entry(ip: "100.1.1.1", fqdn: "a.netbird.cloud",
                                                      url: "https://mgmt.example.com", ipv6: "fd00::1"))
        XCTAssertEqual(cache.entry(forID: "b"), entry(url: "https://b.example.com"))
    }

    func testBlobMigrationDoesNotOverwriteNewerKeys() throws {
        let cache = ProfileConnectionCache(defaults: target)
        cache.save(ip: "100.9.9.9", fqdn: "new.netbird.cloud", forID: "a")
        cache.saveManagementURL("https://new.example.com", forID: "a")
        try writeBlob(["a": entry(ip: "100.1.1.1", fqdn: "old.netbird.cloud",
                                  url: "https://old.example.com")], to: target)

        ProfileConnectionCache.migrateBlobToPerProfileKeysIfNeeded(in: target)

        XCTAssertNil(target.data(forKey: Self.blobKey))
        XCTAssertEqual(cache.entry(forID: "a"), entry(ip: "100.9.9.9", fqdn: "new.netbird.cloud",
                                                      url: "https://new.example.com"))
    }

    func testBlobMigrationKeepsBlobWhenWritesDoNotPersist() throws {
        let droppingName = "nb-cache-test-dropping-\(UUID().uuidString)"
        let dropping = try XCTUnwrap(WriteDroppingDefaults(suiteName: droppingName))
        defer { dropping.removePersistentDomain(forName: droppingName) }
        dropping.dropWrites = false
        try writeBlob(["a": entry(ip: "100.1.1.1", fqdn: "a.netbird.cloud")], to: dropping)
        dropping.dropWrites = true

        ProfileConnectionCache.migrateBlobToPerProfileKeysIfNeeded(in: dropping)

        XCTAssertNotNil(dropping.data(forKey: Self.blobKey))
    }

    func testInitMigratesStandardBlobAllTheWayToKeys() throws {
        try writeBlob(["a": entry(ip: "100.1.1.1", fqdn: "a.netbird.cloud",
                                  url: "https://mgmt.example.com")], to: source)
        migrate()

        let cache = ProfileConnectionCache(defaults: target)

        XCTAssertNil(source.data(forKey: Self.blobKey))
        XCTAssertNil(target.data(forKey: Self.blobKey))
        XCTAssertEqual(cache.entry(forID: "a"), entry(ip: "100.1.1.1", fqdn: "a.netbird.cloud",
                                                      url: "https://mgmt.example.com"))
    }

    // MARK: - Per-key write semantics

    func testIndependentWritersDoNotClobberEachOther() throws {
        // Two cache instances over separate UserDefaults objects for the same
        // suite, mirroring the app and the extension writing concurrently.
        let appSide = ProfileConnectionCache(defaults: try XCTUnwrap(UserDefaults(suiteName: targetName)))
        let extensionSide = ProfileConnectionCache(defaults: try XCTUnwrap(UserDefaults(suiteName: targetName)))

        extensionSide.saveManagementURL("https://mgmt.example.com", forID: "a")
        appSide.save(ip: "100.1.1.1", fqdn: "a.netbird.cloud", forID: "a")

        XCTAssertEqual(ProfileConnectionCache(defaults: target).entry(forID: "a"),
                       entry(ip: "100.1.1.1", fqdn: "a.netbird.cloud", url: "https://mgmt.example.com"))
    }

    func testClearConnectionDataPreservesManagementURL() throws {
        let cache = ProfileConnectionCache(defaults: target)
        cache.save(ip: "100.1.1.1", fqdn: "a.netbird.cloud", ipv6: "fd00::1", forID: "a")
        cache.saveManagementURL("https://mgmt.example.com", forID: "a")

        cache.clearConnectionData(forID: "a")

        XCTAssertEqual(cache.entry(forID: "a"), entry(url: "https://mgmt.example.com"))
        XCTAssertEqual(cache.managementURL(forID: "a"), "https://mgmt.example.com")
    }

    func testRemoveDeletesEverythingForProfile() throws {
        let cache = ProfileConnectionCache(defaults: target)
        cache.save(ip: "100.1.1.1", fqdn: "a.netbird.cloud", forID: "a")
        cache.saveManagementURL("https://mgmt.example.com", forID: "a")

        cache.remove(forID: "a")

        XCTAssertNil(cache.entry(forID: "a"))
        XCTAssertNil(cache.managementURL(forID: "a"))
    }
}

/// Simulates a suite whose writes silently fail (e.g. missing App Group
/// entitlement): set() drops the value, so a read-back returns nothing.
/// dropWrites can be turned off to seed data before exercising the failure.
private final class WriteDroppingDefaults: UserDefaults {
    var dropWrites = true
    override func set(_ value: Any?, forKey defaultName: String) {
        if !dropWrites { super.set(value, forKey: defaultName) }
    }
}
