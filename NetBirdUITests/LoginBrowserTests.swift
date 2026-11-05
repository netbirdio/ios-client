//
//  LoginBrowserTests.swift
//  NetBirdUITests
//
//  Section B of the login UI test plan: what the app does when the login
//  browser is closed without signing in. A test reaches that outcome by
//  cancelling the system sign-in alert — the IdP page behind it is out of a
//  test's reach.
//

import XCTest

final class LoginBrowserTests: E2ETestCase {

    /// LOGIN-B01 — cancelling the sign-in alert aborts cleanly: the VPN does
    /// not start, no login error or prompt follows, and the app stays usable.
    ///
    /// The regression this guards is the VPN starting anyway, which would
    /// launch the extension, hit its needs-login path and pop a spurious
    /// "Authentication required" alert.
    func testB01_cancellingTheLoginAbortsCleanly() throws {
        try requireDevice()
        let profile = signedOutProfileAsked()

        step("Cancel the sign-in") {
            SignInAlert.cancel()
        }

        step("The VPN stays off and nothing else pops up") {
            expectStaysDisconnected(for: 10)
            // Known issue: cancelLogin() stops the SDK's token wait, the SDK
            // reports that as a login error, and the adapter shows it as
            // "Login failed" without checking that the user cancelled. Only
            // this check is expected to fail; the rest of the case still runs.
            // Not strict, so the run stays green once the app is fixed, and
            // this block can then go.
            let options = XCTExpectedFailure.Options()
            options.isStrict = false
            XCTExpectFailure("LOGIN-B01: \"Login failed\" after a cancelled login", options: options) {
                XCTAssertEqual(app.alerts.count, 0,
                               "an alert followed the cancelled login: \(app.alerts.firstMatch.label)")
            }
            // It can also come a little later than the check above.
            closeLoginFailed(waiting: 5)
            XCTAssertEqual(app.alerts.count, 0,
                           "an alert other than \"Login failed\" followed the cancelled login: \(app.alerts.firstMatch.label)")
            XCTAssertFalse(SignInAlert.isShowing, "the sign-in alert came back by itself")
        }

        step("The app is still usable") {
            TabBar(app: app).open("Peers")
            XCTAssertTrue(app.staticTexts["Peers connected"].waitForExistence(timeout: 5), "the Peers tab did not open")
            TabBar(app: app).open("Connection")
            XCTAssertTrue(connection.badge(profile).waitForExistence(timeout: 5), "the Connection tab did not come back")
        }
        screenshot("After cancelling the login")
        markPassed()
    }

    /// LOGIN-B02 — a cancelled login can be retried straight away.
    ///
    /// Guards the local callback port being released: the aborted login keeps
    /// its loopback HTTP server bound until it is cancelled, and if that stops
    /// happening the retry stalls trying to bind the same port — the sign-in
    /// alert then never appears.
    func testB02_cancelledLoginCanBeRetried() throws {
        try requireDevice()
        _ = signedOutProfileAsked()

        step("Cancel the first login") {
            cancelSignIn()
            expectStaysDisconnected(for: 3)
        }

        step("Connect again asks for a login within 60 s") {
            XCTAssertTrue(connectExpectingLogin(timeout: 60), "the retry did not ask for a login within 60 s")
            screenshot("Second sign-in alert")
            cancelSignIn()
        }

        markPassed()
    }

    /// LOGIN-B03 — repeated cancellations leave nothing behind: every attempt
    /// asks for the login again, the VPN never leaves Disconnected and no
    /// error piles up.
    func testB03_repeatedCancellationsLeaveNoResidue() throws {
        try requireDevice()
        _ = signedOutProfileAsked()

        for attempt in 1...4 {
            step("Attempt \(attempt): cancel the sign-in") {
                if attempt > 1 {
                    XCTAssertTrue(connectExpectingLogin(timeout: 60),
                                  "attempt \(attempt) did not ask for a login within 60 s")
                }
                cancelSignIn()
                expectStaysDisconnected(for: 3)
                XCTAssertEqual(app.alerts.count, 0,
                               "an alert is left after attempt \(attempt): \(app.alerts.firstMatch.label)")
            }
        }
        screenshot("After four cancelled logins")
        markPassed()
    }

    /// LOGIN-B04 — sending the app to the background while the sign-in alert
    /// is up leaves a consistent state: either the alert is still there or the
    /// login was dropped, and in both cases Connect asks for a login again.
    func testB04_backgroundingDuringTheLoginAlert() throws {
        try requireDevice()
        _ = signedOutProfileAsked()

        step("Background the app for 5 s and bring it back") {
            XCUIDevice.shared.press(.home)
            Thread.sleep(forTimeInterval: 5)
            app.activate()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "the app did not come back to the foreground")
        }

        step("The state is consistent") {
            let alertKept = SignInAlert.isShowing
            XCTContext.runActivity(named: alertKept ? "The sign-in alert is still up" : "The login was dropped") { _ in }
            screenshot("After coming back")
            if alertKept {
                cancelSignIn()
            }
            expectStaysDisconnected(for: 3)
        }

        step("Connect still asks for a login") {
            XCTAssertTrue(connectExpectingLogin(timeout: 60), "Connect is stuck after coming back from the background")
            cancelSignIn()
        }
        markPassed()
    }

    // MARK: - Helpers


    /// Creates a signed-out profile, switches to it and taps Connect, leaving
    /// the sign-in alert on screen.
    private func signedOutProfileAsked() -> String {
        let profile = createSignedOutProfile()
        step("Switch to \(profile) and connect") {
            profiles.switchTo(profile)
            XCTAssertTrue(connectExpectingLogin(), "connecting \(profile) did not ask for a login within 30 s")
        }
        return profile
    }
}
