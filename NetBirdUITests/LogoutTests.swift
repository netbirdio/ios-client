//
//  LogoutTests.swift
//  NetBirdUITests
//
//  Section G of the login UI test plan: logging a profile out.
//

import XCTest

final class LogoutTests: E2ETestCase {

    /// LOGIN-G01 — a logout forces a login on the next connect: a profile
    /// that connected without one before asks for it once logged out.
    /// (LOGIN-S02 walks the same path with the confirmation text checked.)
    func testG01_logoutForcesLoginOnNextConnect() throws {
        try requireDevice()
        let profile = try createSignedInProfile()

        step("\(profile) connects without a login") {
            profiles.switchTo(profile)
            connectWithoutLogin()
            connection.disconnect()
        }

        step("Log \(profile) out") {
            profiles.open()
            profiles.switchTo(startingProfile)
            profiles.logout(profile)
        }

        step("Connecting \(profile) asks for a login") {
            profiles.switchTo(profile)
            XCTAssertTrue(connectExpectingLogin(), "the logged-out profile connected without a login")
            cancelSignIn()
        }
        markPassed()
    }

    /// LOGIN-G03 — the server survives a logout. Logout deletes the profile's
    /// config and state but keeps its management URL; losing it would send
    /// the next login to NetBird Cloud and register the peer in the wrong
    /// account, unnoticed.
    ///
    /// Needs no connect, so it also runs in the Simulator.
    func testG03_serverSurvivesLogout() throws {
        // Created signed in, and — as creating never switches — not active,
        // which is what the Logout action needs.
        let profile = try createSignedInProfile()

        step("Log \(profile) out") {
            profiles.logout(profile)
        }

        step("\(profile) still shows its server") {
            let details = profiles.details(of: profile)
            XCTAssertTrue(details.contains { $0.contains("api.netbird.io") },
                          "after the logout the row shows: \(details)")
        }

        step("…also after a relaunch") {
            relaunch()
            profiles.open()
            let details = profiles.details(of: profile)
            XCTAssertTrue(details.contains { $0.contains("api.netbird.io") },
                          "after the logout and a relaunch the row shows: \(details)")
        }
        screenshot("Logged out, server kept")
        markPassed()
    }
}
