//
//  ProfileConnectionCacheTests.swift
//  NetBirdTests
//
//  Verifies the one-time standard → App Group suite migration of the profile
//  connection cache: legacy entries are merged field by field (suite values
//  win, legacy fills the gaps), and the standard-domain copy is removed only
//  after a verified read-back of the merged data — a suite write that silently
//  fails must not destroy the last remaining copy.
//
//  The migration source and target are injected as plain named suites, so
//  these tests do not touch the real standard domain or the App Group.
//

import XCTest
@testable import NetBird

final class ProfileConnectionCacheTests: XCTestCase {

    private static let storageKey = "netbird_profiles_connection_data"

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

    private func write(_ entries: [String: ProfileConnectionEntry], to defaults: UserDefaults) throws {
        defaults.set(try JSONEncoder().encode(entries), forKey: Self.storageKey)
    }

    private func read(_ defaults: UserDefaults) throws -> [String: ProfileConnectionEntry]? {
        guard let data = defaults.data(forKey: Self.storageKey) else { return nil }
        return try JSONDecoder().decode([String: ProfileConnectionEntry].self, from: data)
    }

    private func entry(ip: String = "", fqdn: String = "",
                       url: String? = nil, ipv6: String? = nil) -> ProfileConnectionEntry {
        return ProfileConnectionEntry(ip: ip, fqdn: fqdn, managementURL: url, ipv6: ipv6)
    }

    // MARK: - Tests

    func testMovesLegacyIntoEmptySuite() throws {
        try write(["a": entry(ip: "100.1.1.1", fqdn: "a.netbird.cloud",
                              url: "https://mgmt.example.com:443")], to: source)

        migrate()

        let migrated = try XCTUnwrap(try read(target))
        XCTAssertEqual(migrated["a"], entry(ip: "100.1.1.1", fqdn: "a.netbird.cloud",
                                            url: "https://mgmt.example.com:443"))
        XCTAssertNil(source.data(forKey: Self.storageKey))
    }

    func testMergesLegacyProfileMissingFromSuite() throws {
        try write(["a": entry(url: "https://suite.example.com")], to: target)
        try write(["b": entry(ip: "100.2.2.2", fqdn: "b.netbird.cloud")], to: source)

        migrate()

        let merged = try XCTUnwrap(try read(target))
        XCTAssertEqual(merged["a"], entry(url: "https://suite.example.com"))
        XCTAssertEqual(merged["b"], entry(ip: "100.2.2.2", fqdn: "b.netbird.cloud"))
        XCTAssertNil(source.data(forKey: Self.storageKey))
    }

    func testFillsEmptyFieldsFromLegacy() throws {
        // The extension seeds URL-only entries before the app first runs after
        // the upgrade (on-demand VPN): the legacy ip/fqdn must survive the merge.
        try write(["a": entry(url: "https://suite.example.com")], to: target)
        try write(["a": entry(ip: "100.1.1.1", fqdn: "a.netbird.cloud",
                              url: "https://legacy.example.com", ipv6: "fd00::1")], to: source)

        migrate()

        let merged = try XCTUnwrap(try read(target))
        XCTAssertEqual(merged["a"], entry(ip: "100.1.1.1", fqdn: "a.netbird.cloud",
                                          url: "https://suite.example.com", ipv6: "fd00::1"))
    }

    func testSuiteValuesWinOnConflict() throws {
        try write(["a": entry(ip: "100.9.9.9", fqdn: "new.netbird.cloud",
                              url: "https://suite.example.com")], to: target)
        try write(["a": entry(ip: "100.1.1.1", fqdn: "old.netbird.cloud",
                              url: "https://legacy.example.com")], to: source)

        migrate()

        let merged = try XCTUnwrap(try read(target))
        XCTAssertEqual(merged["a"], entry(ip: "100.9.9.9", fqdn: "new.netbird.cloud",
                                          url: "https://suite.example.com"))
    }

    func testKeepsLegacyWhenSuiteWriteDoesNotPersist() throws {
        try write(["a": entry(ip: "100.1.1.1", fqdn: "a.netbird.cloud")], to: source)
        let dropping = try XCTUnwrap(
            WriteDroppingDefaults(suiteName: "nb-cache-test-dropping-\(UUID().uuidString)"))

        ProfileConnectionCache.migrateFromStandardIfNeeded(from: source, into: dropping)

        XCTAssertNotNil(source.data(forKey: Self.storageKey))
    }

    func testRemovesUndecodableLegacyBlob() throws {
        source.set(Data("not json".utf8), forKey: Self.storageKey)
        try write(["a": entry(url: "https://suite.example.com")], to: target)

        migrate()

        XCTAssertNil(source.data(forKey: Self.storageKey))
        let kept = try XCTUnwrap(try read(target))
        XCTAssertEqual(kept["a"], entry(url: "https://suite.example.com"))
    }

    func testNoopWhenTargetIsSource() throws {
        try write(["a": entry(ip: "100.1.1.1", fqdn: "a.netbird.cloud")], to: source)

        ProfileConnectionCache.migrateFromStandardIfNeeded(from: source, into: source)

        XCTAssertNotNil(source.data(forKey: Self.storageKey))
    }

    func testMigrationIsIdempotent() throws {
        try write(["a": entry(url: "https://suite.example.com")], to: target)
        try write(["b": entry(ip: "100.2.2.2", fqdn: "b.netbird.cloud")], to: source)

        migrate()
        let first = try read(target)
        migrate()

        XCTAssertEqual(try read(target), first)
    }
}

/// Simulates a suite whose writes silently fail (e.g. missing App Group
/// entitlement): set() drops the value, so a read-back returns nothing.
private final class WriteDroppingDefaults: UserDefaults {
    override func set(_ value: Any?, forKey defaultName: String) {}
}
