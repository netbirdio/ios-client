//
//  ProfileManagementTests.swift
//  NetBirdUITests
//
//  Section F of the login test plan: managing profiles.
//

import XCTest

final class ProfileManagementTests: E2ETestCase {

    /// LOGIN-F01 — switching to a profile that has not signed in asks for a
    /// login on connect, even right after a signed-in profile was in use.
    func testF01_switchingToSignedOutProfileAsksForLogin() throws {
        try requireDevice()
        let signedIn = try createSignedInProfile()
        let signedOut = createSignedOutProfile()

        step("Use \(signedIn) first") {
            profiles.switchTo(signedIn)
            connectWithoutLogin()
        }

        step("Switch to \(signedOut) and connect: a login is asked for") {
            profiles.open()
            profiles.switchTo(signedOut)
            XCTAssertTrue(connectExpectingLogin(), "connecting \(signedOut) did not ask for a login within 30 s")
            screenshot("Sign-in asked for \(signedOut)")
            cancelSignIn()
            expectStaysDisconnected(for: 3)
        }
        markPassed()
    }

    /// LOGIN-F02 — switching back to a signed-in profile connects without a
    /// login: the signed-out profile's cancelled login does not leak into it.
    func testF02_switchingBackToSignedInProfileNeedsNoLogin() throws {
        try requireDevice()
        let signedIn = try createSignedInProfile()
        let signedOut = createSignedOutProfile()

        step("Ask for a login on \(signedOut) and cancel it") {
            profiles.switchTo(signedOut)
            XCTAssertTrue(connectExpectingLogin(), "connecting \(signedOut) did not ask for a login within 30 s")
            cancelSignIn()
            expectStaysDisconnected(for: 3)
        }

        step("Switch back to \(signedIn) and connect without a login") {
            profiles.open()
            profiles.switchTo(signedIn)
            connectWithoutLogin()
        }
        screenshot("Connected on \(signedIn)")
        markPassed()
    }

    /// LOGIN-F04 — logging one profile out leaves another signed in: the
    /// other still connects without a login, while the logged-out one asks.
    func testF04_logoutOfOneProfileLeavesTheOtherSignedIn() throws {
        try requireDevice()
        let first = try createSignedInProfile()
        let second = try createSignedInProfile()

        step("Log \(first) out") {
            profiles.logout(first)
        }

        step("\(second) still connects without a login") {
            profiles.switchTo(second)
            connectWithoutLogin()
            connection.disconnect()
        }

        step("\(first) asks for a login") {
            profiles.open()
            profiles.switchTo(first)
            XCTAssertTrue(connectExpectingLogin(), "the logged-out \(first) connected without asking for a login")
            cancelSignIn()
        }
        markPassed()
    }

    /// LOGIN-F05 — neither the default profile nor the active one can be
    /// removed. The app does not offer the action at all: the default row's
    /// swipe actions hold Logout but no Remove, and the active row has none.
    func testF05_defaultAndActiveProfilesCannotBeRemoved() {
        let profile = newProfileName()

        step("Make \(profile) active, so default is listed among the others") {
            profiles.open()
            profiles.create(profile)
            profiles.switchTo(profile)
        }

        step("default offers Logout but no Remove") {
            guard let row = profiles.row("default") else {
                XCTFail("default is not under All Profiles")
                return
            }
            row.swipeLeft()
            XCTAssertTrue(app.buttons["Logout"].waitForExistence(timeout: 3),
                          "the swipe on default did not reveal its actions")
            XCTAssertFalse(app.buttons["Remove"].exists, "default can be removed")
            screenshot("default swipe actions")
            // Close the actions without choosing one.
            row.swipeRight()
        }

        step("The active profile offers no actions") {
            let active = app.cells.containing(.staticText, identifier: profile).firstMatch
            XCTAssertTrue(active.exists, "no row for the active profile")
            active.swipeLeft()
            XCTAssertFalse(app.buttons["Remove"].waitForExistence(timeout: 2), "the active profile can be removed")
            XCTAssertFalse(app.buttons["Logout"].exists, "the active profile offers Logout in the list")
            screenshot("Active profile swipe")
        }

        markPassed()
    }
}
