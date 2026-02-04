//
//  GlobalConstantsTests.swift
//  NetBirdTests
//

import XCTest
@testable import NetBird

final class GlobalConstantsTests: XCTestCase {

    func testForceRelayConnectionKey() {
        XCTAssertEqual(GlobalConstants.keyForceRelayConnection, "isConnectionForceRelayed")
    }

    func testLoginRequiredKey() {
        XCTAssertEqual(GlobalConstants.keyLoginRequired, "netbird.loginRequired")
    }

    func testUserPreferencesSuiteName() {
        XCTAssertEqual(GlobalConstants.userPreferencesSuiteName, "group.io.netbird.helicon.app")
    }
}
