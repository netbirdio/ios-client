//
//  SharedUserDefaultsTests.swift
//  NetBirdTests
//

import XCTest
@testable import NetBird

final class SharedUserDefaultsTests: XCTestCase {

    var userDefaults: UserDefaults?

    override func setUpWithError() throws {
        try super.setUpWithError()
        userDefaults = UserDefaults(suiteName: GlobalConstants.userPreferencesSuiteName)
        guard userDefaults != nil else {
            throw XCTSkip("Shared UserDefaults suite not available (app group may not be configured)")
        }
    }

    override func tearDown() {
        userDefaults?.removeObject(forKey: GlobalConstants.keyLoginRequired)
        userDefaults?.removeObject(forKey: GlobalConstants.keyForceRelayConnection)
        userDefaults?.removeObject(forKey: GlobalConstants.keyEnableLazyConnection)
        super.tearDown()
    }

    func testUserDefaultsSuiteExists() throws {
        let defaults = try XCTUnwrap(userDefaults, "Shared UserDefaults suite should exist")
        XCTAssertNotNil(defaults)
    }

    func testLoginRequiredFlagDefaultsToFalse() throws {
        let defaults = try XCTUnwrap(userDefaults)
        defaults.removeObject(forKey: GlobalConstants.keyLoginRequired)
        let value = defaults.bool(forKey: GlobalConstants.keyLoginRequired)
        XCTAssertFalse(value, "Login required flag should default to false")
    }

    func testLoginRequiredFlagCanBeSet() throws {
        let defaults = try XCTUnwrap(userDefaults)
        defaults.set(true, forKey: GlobalConstants.keyLoginRequired)
        let value = defaults.bool(forKey: GlobalConstants.keyLoginRequired)
        XCTAssertTrue(value, "Login required flag should be true after setting")
    }

    func testLoginRequiredFlagCanBeCleared() throws {
        let defaults = try XCTUnwrap(userDefaults)
        defaults.set(true, forKey: GlobalConstants.keyLoginRequired)
        defaults.set(false, forKey: GlobalConstants.keyLoginRequired)
        let value = defaults.bool(forKey: GlobalConstants.keyLoginRequired)
        XCTAssertFalse(value, "Login required flag should be false after clearing")
    }

    func testForceRelayConnectionDefaultsToTrue() throws {
        let defaults = try XCTUnwrap(userDefaults)
        defaults.removeObject(forKey: GlobalConstants.keyForceRelayConnection)
        defaults.register(defaults: [GlobalConstants.keyForceRelayConnection: true])
        let value = defaults.bool(forKey: GlobalConstants.keyForceRelayConnection)
        XCTAssertTrue(value, "Force relay connection should default to true")
    }

    func testEnableLazyConnectionDefaultsToTrue() throws {
        let defaults = try XCTUnwrap(userDefaults)
        defaults.removeObject(forKey: GlobalConstants.keyEnableLazyConnection)
        defaults.register(defaults: [GlobalConstants.keyEnableLazyConnection: true])
        let value = defaults.bool(forKey: GlobalConstants.keyEnableLazyConnection)
        XCTAssertTrue(value, "Enable lazy connection should default to true")
    }
}
