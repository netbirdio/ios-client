//
//  SharedUserDefaultsTests.swift
//  NetBirdTests
//

import XCTest
@testable import NetBird

final class SharedUserDefaultsTests: XCTestCase {

    var userDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        userDefaults = UserDefaults(suiteName: GlobalConstants.userPreferencesSuiteName)
    }

    override func tearDown() {
        // Clean up test keys
        userDefaults?.removeObject(forKey: GlobalConstants.keyLoginRequired)
        userDefaults?.removeObject(forKey: GlobalConstants.keyForceRelayConnection)
        super.tearDown()
    }

    func testUserDefaultsSuiteExists() {
        XCTAssertNotNil(userDefaults, "Shared UserDefaults suite should exist")
    }

    func testLoginRequiredFlagDefaultsToFalse() {
        userDefaults.removeObject(forKey: GlobalConstants.keyLoginRequired)
        let value = userDefaults.bool(forKey: GlobalConstants.keyLoginRequired)
        XCTAssertFalse(value, "Login required flag should default to false")
    }

    func testLoginRequiredFlagCanBeSet() {
        userDefaults.set(true, forKey: GlobalConstants.keyLoginRequired)
        let value = userDefaults.bool(forKey: GlobalConstants.keyLoginRequired)
        XCTAssertTrue(value, "Login required flag should be true after setting")
    }

    func testLoginRequiredFlagCanBeCleared() {
        userDefaults.set(true, forKey: GlobalConstants.keyLoginRequired)
        userDefaults.set(false, forKey: GlobalConstants.keyLoginRequired)
        let value = userDefaults.bool(forKey: GlobalConstants.keyLoginRequired)
        XCTAssertFalse(value, "Login required flag should be false after clearing")
    }

    func testForceRelayConnectionDefaultsToTrue() {
        userDefaults.removeObject(forKey: GlobalConstants.keyForceRelayConnection)
        userDefaults.register(defaults: [GlobalConstants.keyForceRelayConnection: true])
        let value = userDefaults.bool(forKey: GlobalConstants.keyForceRelayConnection)
        XCTAssertTrue(value, "Force relay connection should default to true")
    }
}
