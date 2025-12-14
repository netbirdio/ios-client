//
//  AppLoggerTests.swift
//  NetBirdTests
//

import XCTest
@testable import NetBird

final class AppLoggerTests: XCTestCase {

    func testSharedInstanceExists() {
        let logger = AppLogger.shared
        XCTAssertNotNil(logger)
    }

    func testSharedInstanceIsSingleton() {
        let logger1 = AppLogger.shared
        let logger2 = AppLogger.shared
        XCTAssertTrue(logger1 === logger2)
    }

    func testLogDoesNotCrash() {
        // Verify logging doesn't throw or crash
        AppLogger.shared.log("Test message")
        AppLogger.shared.log("Test message with special chars: !@#$%^&*()")
        AppLogger.shared.log("")
    }

    func testGetLogFileURLReturnsURL() {
        // May return nil if log file hasn't been created yet
        // Just verify the method doesn't crash
        _ = AppLogger.getLogFileURL()
    }

    func testGetGoLogFileURLReturnsURL() {
        // May return nil if Go log file doesn't exist
        // Just verify the method doesn't crash
        _ = AppLogger.getGoLogFileURL()
    }
}
