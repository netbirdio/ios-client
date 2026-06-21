//
//  ProfileMigrationTests.swift
//  NetBirdTests
//
//  Verifies the one-time legacy → Go profile-layout migration and reads the
//  result back THROUGH the Go library (NetBirdSDKProfileManager), then exercises
//  the settings primitive (NetBirdSDKPreferences — the same type the settings
//  screen drives via iOSConfigurationProvider) against a single profile's config
//  and reads it back.
//
//  Note: the NetBirdTests target links NetBirdSDK.xcframework, so the Go lib is
//  available here. These tests run on the iOS simulator (the migration and the
//  iOS profile manager are iOS-only).
//

#if os(iOS)

import XCTest
import NetBirdSDK
@testable import NetBird

final class ProfileMigrationTests: XCTestCase {

    private var configDir: String!

    override func setUpWithError() throws {
        // A fresh, isolated container directory per test.
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("nb-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        configDir = base.path
    }

    override func tearDownWithError() throws {
        if let dir = configDir { try? FileManager.default.removeItem(atPath: dir) }
        configDir = nil
    }

    // MARK: - Legacy layout builder

    /// Writes a legacy Swift-layout profile directory:
    ///   <configDir>/profiles/profiles.json          { activeProfile, deletedProfiles }
    ///   <configDir>/profiles/<name>/netbird.cfg      (optional — absent means logged out)
    ///   <configDir>/profiles/<name>/state.json       (optional)
    ///   <configDir>/profiles/<name>/netbird_server_url (optional)
    private func makeLegacyProfile(_ name: String, config: [String: Any]?, serverURL: String? = nil) throws {
        let dir = (configDir as NSString)
            .appendingPathComponent("profiles")
            .appending("/\(name)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let config {
            let data = try JSONSerialization.data(withJSONObject: config)
            try data.write(to: URL(fileURLWithPath: (dir as NSString).appendingPathComponent("netbird.cfg")))
            // A plausible state file alongside the config.
            try Data("{}".utf8).write(to: URL(fileURLWithPath: (dir as NSString).appendingPathComponent("state.json")))
        }
        if let serverURL {
            try serverURL.write(toFile: (dir as NSString).appendingPathComponent("netbird_server_url"),
                                atomically: true, encoding: .utf8)
        }
    }

    private func writeLegacyMeta(active: String, deleted: [String] = []) throws {
        let profilesDir = (configDir as NSString).appendingPathComponent("profiles")
        try FileManager.default.createDirectory(atPath: profilesDir, withIntermediateDirectories: true)
        let meta: [String: Any] = ["activeProfile": active, "deletedProfiles": deleted]
        let data = try JSONSerialization.data(withJSONObject: meta)
        try data.write(to: URL(fileURLWithPath: (profilesDir as NSString).appendingPathComponent("profiles.json")))
    }

    // MARK: - Path / JSON helpers

    private func path(_ components: String...) -> String {
        components.reduce(configDir!) { ($0 as NSString).appendingPathComponent($1) }
    }

    private func readJSON(_ p: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: p) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func exists(_ p: String) -> Bool { FileManager.default.fileExists(atPath: p) }

    // Builds the Go profile manager over the test's container.
    private func makeGoManager() throws -> NetBirdSDKProfileManager {
        try XCTUnwrap(NetBirdSDKNewProfileManager(configDir), "Go profile manager must be created")
    }

    private func listProfiles(_ pm: NetBirdSDKProfileManager) throws -> [(id: String, name: String, active: Bool)] {
        let array = try pm.listProfiles()
        var out: [(String, String, Bool)] = []
        for i in 0..<array.length() {
            if let p = array.get(i) { out.append((p.id_, p.name, p.isActive)) }
        }
        return out
    }

    // MARK: - Migration → Go readback

    func testDefaultStaysDefaultAtRootNotUUID() throws {
        try writeLegacyMeta(active: "default")
        try makeLegacyProfile("default", config: ["ManagementURL": "https://api.netbird.io:443", "PrivateKey": "DEFKEY"])

        ProfileLayoutMigration.runIfNeeded(configDir: configDir)

        // Default config lives at the container ROOT as netbird.cfg, never as a
        // hex/UUID file under profiles/.
        XCTAssertTrue(exists(path("netbird.cfg")), "default config should be at root netbird.cfg")
        XCTAssertEqual(readJSON(path("netbird.cfg"))?["PrivateKey"] as? String, "DEFKEY",
                       "default auth token must be preserved")
        XCTAssertFalse(exists(path("profiles", "default.json")), "default must not become a profiles/ file")

        // Go sees exactly one profile: default, id == \"default\", active.
        let pm = try makeGoManager()
        let profiles = try listProfiles(pm)
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles.first?.id, "default")
        XCTAssertTrue(profiles.first?.active ?? false)

        let active = try pm.getActiveProfile()
        XCTAssertEqual(active.id_, "default")
        XCTAssertEqual(try pm.getActiveConfigPath(), path("netbird.cfg"))
    }

    func testNamedProfileMigratesToIdFileAndGoReadsItBack() throws {
        try writeLegacyMeta(active: "work")
        try makeLegacyProfile("default", config: ["ManagementURL": "https://api.netbird.io:443"])
        try makeLegacyProfile("work", config: ["ManagementURL": "https://vpn.corp.example:443", "PrivateKey": "WORKKEY"])

        ProfileLayoutMigration.runIfNeeded(configDir: configDir)

        // Non-default profile keeps its NAME as ID (no re-keying to hex) and
        // becomes a flat <id>.json with the display name stamped in.
        let workCfg = path("profiles", "work.json")
        XCTAssertTrue(exists(workCfg), "named profile should migrate to profiles/work.json")
        XCTAssertEqual(readJSON(workCfg)?["Name"] as? String, "work", "display name should be stamped into config")
        XCTAssertEqual(readJSON(workCfg)?["PrivateKey"] as? String, "WORKKEY", "auth token must be preserved")
        // Old directory layout is gone.
        XCTAssertFalse(exists(path("profiles", "work")), "legacy profile directory should be removed")
        XCTAssertFalse(exists(path("profiles", "profiles.json")), "legacy meta should be removed")

        // Go readback: both profiles present, \"work\" active.
        let pm = try makeGoManager()
        let profiles = try listProfiles(pm)
        XCTAssertEqual(Set(profiles.map { $0.id }), ["default", "work"])
        XCTAssertEqual(profiles.first(where: { $0.id == "work" })?.name, "work")
        XCTAssertTrue(profiles.first(where: { $0.id == "work" })?.active ?? false)
        XCTAssertFalse(profiles.first(where: { $0.id == "default" })?.active ?? true)

        XCTAssertEqual(try pm.getActiveProfile().id_, "work")
        XCTAssertEqual(try pm.getActiveConfigPath(), workCfg)
        XCTAssertEqual(try pm.getActiveStateFilePath(), path("profiles", "work.state.json"))
    }

    func testLoggedOutProfileStillListedWithServerURL() throws {
        // A logged-out legacy profile has no netbird.cfg, only the server URL sidecar.
        try writeLegacyMeta(active: "default")
        try makeLegacyProfile("default", config: ["ManagementURL": "https://api.netbird.io:443"])
        try makeLegacyProfile("home", config: nil, serverURL: "https://home.example:443")

        ProfileLayoutMigration.runIfNeeded(configDir: configDir)

        let homeCfg = path("profiles", "home.json")
        XCTAssertTrue(exists(homeCfg), "logged-out profile must still get a config so it stays visible")
        let json = readJSON(homeCfg)
        XCTAssertEqual(json?["Name"] as? String, "home")
        XCTAssertNil(json?["PrivateKey"], "logged-out profile must have no auth token")
        // ManagementURL recovered from the sidecar as the nested object form.
        let mgmt = json?["ManagementURL"] as? [String: Any]
        XCTAssertEqual(mgmt?["Host"] as? String, "home.example:443")

        let pm = try makeGoManager()
        XCTAssertTrue(try listProfiles(pm).contains { $0.id == "home" })
    }

    func testDeletedProfileIsNotMigrated() throws {
        try writeLegacyMeta(active: "default", deleted: ["old"])
        try makeLegacyProfile("default", config: ["ManagementURL": "https://api.netbird.io:443"])
        try makeLegacyProfile("old", config: ["ManagementURL": "https://old.example:443"])

        ProfileLayoutMigration.runIfNeeded(configDir: configDir)

        XCTAssertFalse(exists(path("profiles", "old.json")), "tombstoned profile must not be migrated")
        XCTAssertFalse(exists(path("profiles", "old")), "tombstoned directory must be removed")
        let pm = try makeGoManager()
        XCTAssertFalse(try listProfiles(pm).contains { $0.id == "old" })
    }

    // MARK: - Settings feature round-trip through the profile manager

    /// Drives the SAME Go primitive the settings screen uses (NetBirdSDKPreferences,
    /// wrapped by iOSConfigurationProvider) against ONE profile's config path as
    /// resolved by the profile manager, then reads the value back. Also asserts the
    /// other profile's config is untouched — i.e. settings write only the targeted
    /// profile.
    func testSettingsModificationTargetsResolvedProfileAndReadsBack() throws {
        try writeLegacyMeta(active: "work")
        try makeLegacyProfile("default", config: ["ManagementURL": "https://api.netbird.io:443", "DisableIPv6": false])
        try makeLegacyProfile("work", config: ["ManagementURL": "https://vpn.corp.example:443", "DisableIPv6": false])

        ProfileLayoutMigration.runIfNeeded(configDir: configDir)

        let pm = try makeGoManager()

        // The profile manager resolves the active profile's config/state paths —
        // exactly what Preferences.configFile()/stateFile() return on iOS.
        let workConfig = try pm.getConfigPath("work")
        let workState = try pm.getStateFilePath("work")
        let defaultConfig = try pm.getConfigPath("default")
        let defaultBefore = try XCTUnwrap(FileManager.default.contents(atPath: defaultConfig))

        // Apply a settings change through NetBirdSDKPreferences (the settings stack).
        let prefs = try XCTUnwrap(NetBirdSDKNewPreferences(workConfig, workState))
        prefs.setDisableIPv6(true)
        try prefs.commit()

        // Read it back through a fresh Preferences instance on the same profile.
        let reopened = try XCTUnwrap(NetBirdSDKNewPreferences(workConfig, workState))
        var value = ObjCBool(false)
        try reopened.getDisableIPv6(&value)
        XCTAssertTrue(value.boolValue, "DisableIPv6 written via settings should round-trip for the work profile")

        // The change landed in the work profile's config file...
        XCTAssertEqual(readJSON(workConfig)?["DisableIPv6"] as? Bool, true)
        // ...and the default profile's config is byte-for-byte unchanged.
        let defaultAfter = try XCTUnwrap(FileManager.default.contents(atPath: defaultConfig))
        XCTAssertEqual(defaultBefore, defaultAfter, "settings must not touch a non-targeted profile")
    }

    // MARK: - Idempotency / guards

    func testReRunIsIdempotent() throws {
        try writeLegacyMeta(active: "work")
        try makeLegacyProfile("default", config: ["ManagementURL": "https://api.netbird.io:443"])
        try makeLegacyProfile("work", config: ["ManagementURL": "https://vpn.corp.example:443", "PrivateKey": "WORKKEY"])

        ProfileLayoutMigration.runIfNeeded(configDir: configDir)
        let firstActive = try readJSON(path("active_profile.json"))?["name"] as? String
        let firstWork = FileManager.default.contents(atPath: path("profiles", "work.json"))

        // Second run must be a no-op (marker guards it) and must not corrupt data.
        ProfileLayoutMigration.runIfNeeded(configDir: configDir)
        let secondWork = FileManager.default.contents(atPath: path("profiles", "work.json"))

        XCTAssertEqual(firstActive, "work")
        XCTAssertEqual(firstWork, secondWork, "re-running migration must leave files unchanged")

        // Go still reads a coherent state after the second run.
        let pm = try makeGoManager()
        XCTAssertEqual(try pm.getActiveProfile().id_, "work")
        XCTAssertEqual(Set(try listProfiles(pm).map { $0.id }), ["default", "work"])
    }

    func testNoLegacyLayoutWritesMarkerWithoutCreatingProfiles() throws {
        // Fresh install: no profiles/ dir at all.
        ProfileLayoutMigration.runIfNeeded(configDir: configDir)

        XCTAssertTrue(exists(path("profiles_migrated_to_go_v1")), "marker should be written even with nothing to migrate")
        XCTAssertFalse(exists(path("profiles", "profiles.json")))

        // Go still yields the implicit default profile.
        let pm = try makeGoManager()
        XCTAssertEqual(try pm.getActiveProfile().id_, "default")
    }
}

#endif
