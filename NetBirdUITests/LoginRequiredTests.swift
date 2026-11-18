//
//  LoginRequiredTests.swift
//  NetBirdUITests
//
//  Section A of the login UI test plan: the app asks for a login exactly when
//  one is needed. A test sees the request as the system sign-in alert iOS
//  shows before the browser opens; it never goes past that alert.
//

import XCTest

final class LoginRequiredTests: E2ETestCase {

    /// LOGIN-A01 — a profile that never signed in asks for a login on its
    /// first connect, and does not connect before it.
    ///
    /// The plan starts from a reset app; the test cannot reset the unmodified
    /// app, so a freshly created profile stands in for a fresh install — it
    /// has no identity on the server either.
    func testA01_newProfileAsksForLogin() throws {
        try requireDevice()
        let profile = newProfileName()

        step("Create \(profile) without a setup key and switch to it") {
            profiles.open()
            profiles.create(profile)
            profiles.switchTo(profile)
        }

        step("Connect asks for a login within 30 s") {
            XCTAssertTrue(connectExpectingLogin(timeout: 30), "no sign-in alert within 30 s of Connect")
            XCTAssertNotEqual(connection.state, "Connected",
                              "the VPN reached Connected before the login")
            screenshot("Sign-in asked for \(profile)")
            cancelSignIn()
        }

        markPassed()
    }

    // LOGIN-A05 (an unreachable server never reports Connected) cannot be
    // set up through the UI: the plan seeds a profile pointing at an
    // unroutable server, but the app only saves a server it can reach — the
    // attempt is LOGIN-E03, which checks that it is refused.

    // LOGIN-A02 (a signed-in profile connects without a browser) is what
    // E2E-001, SetupKeyAuthTests.testLoginWithSetupKeyViaUi, checks: it fails
    // if the sign-in alert shows up on the way to Connected.

    /// LOGIN-A03 — reconnecting after a clean disconnect does not ask for a
    /// login again.
    func testA03_reconnectStaysWithoutLogin() throws {
        try requireDevice()
        let profile = try createSignedInProfile()

        step("Switch to \(profile) and connect") {
            profiles.switchTo(profile)
            connectWithoutLogin()
        }
        step("Disconnect") {
            connection.disconnect()
        }
        step("Connect again, still without a login") {
            connectWithoutLogin()
        }
        screenshot("Reconnected on \(profile)")
        markPassed()
    }

    /// LOGIN-A04 — repeated connect cycles do not degrade: three in a row all
    /// reach Connected, with no login asked for and no login error.
    ///
    /// The management server bans a peer after 30 logins within 5 minutes.
    /// Three cycles stay well inside that; if a regression brings back
    /// redundant logins, this is where a ban would show first — as a cycle
    /// that stops connecting partway through.
    func testA04_repeatedConnectCyclesDoNotDegrade() throws {
        try requireDevice()
        let profile = try createSignedInProfile()
        profiles.switchTo(profile)

        for cycle in 1...3 {
            step("Cycle \(cycle): connect, then disconnect") {
                connectWithoutLogin()
                connection.disconnect()
            }
        }
        markPassed()
    }
}
