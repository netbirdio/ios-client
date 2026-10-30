//
//  LoginBaselineTests.swift
//  NetBirdUITests
//
//  Section S of the login UI test plan (login-ui-test-cases.md): the
//  everyday flows, one case each.
//

import XCTest

final class LoginBaselineTests: E2ETestCase {

    /// LOGIN-S02 — Basic logout.
    ///
    /// A signed-in profile is used, then logged out from the profile list.
    /// The app offers Logout only on profiles that are not active, so the test
    /// switches back to the starting profile first. After the logout the
    /// profile keeps its server, and its next connect asks for a login again.
    ///
    /// The plan's profile signs in with SSO and checks its account email
    /// disappears; a setup-key profile has no email to lose, so that check is
    /// replaced by the login being asked for again.
    func testS02_basicLogout() throws {
        try requireDevice()
        let profile = try createSignedInProfile()

        step("Use \(profile): it connects without a login") {
            profiles.switchTo(profile)
            connectWithoutLogin()
            connection.disconnect()
        }

        step("Switch back to \(startingProfile) and log \(profile) out") {
            profiles.open()
            profiles.switchTo(startingProfile)
            profiles.logout(profile, checkingMessage: true)
            let details = profiles.details(of: profile)
            XCTAssertTrue(details.contains { $0.contains("api.netbird.io") },
                          "the logged-out profile lost its server: \(details)")
        }
        screenshot("After logging \(profile) out")

        step("Connecting \(profile) asks for a login again") {
            profiles.switchTo(profile)
            XCTAssertTrue(connectExpectingLogin(), "a logged-out profile connected without asking for a login")
            cancelSignIn()
        }
        markPassed()
    }

    /// LOGIN-S04 — Switch between existing profiles.
    ///
    /// Two signed-in profiles: a cancelled switch changes nothing, a confirmed
    /// one disconnects and makes the other profile active, and both connect
    /// without a login on the way there and back.
    func testS04_switchBetweenExistingProfiles() throws {
        try requireDevice()
        let first = try createSignedInProfile()
        let second = try createSignedInProfile()

        step("Connect \(first)") {
            profiles.switchTo(first)
            connectWithoutLogin()
        }

        step("A cancelled switch to \(second) changes nothing") {
            profiles.open()
            profiles.cancelSwitch(to: second)
            XCTAssertEqual(profiles.activeProfileName, first, "the active profile changed despite Cancel")
            TabBar(app: app).open("Connection")
            XCTAssertEqual(connection.state, "Connected", "the VPN dropped despite Cancel")
        }

        step("Switching to \(second) disconnects and makes it active") {
            profiles.open()
            profiles.switchTo(second)
            TabBar(app: app).open("Connection")
            XCTAssertTrue(connection.badge(second).waitForExistence(timeout: 5), "the badge does not read \(second)")
            let disconnected = NSPredicate(format: "value == %@", "Disconnected")
            XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: disconnected, object: connection.toggle)],
                                            timeout: 15), .completed, "the VPN did not disconnect on the switch")
        }

        step("\(second) connects without a login") {
            connectWithoutLogin()
        }

        step("Back to \(first): it connects without a login too") {
            profiles.open()
            profiles.switchTo(first)
            connectWithoutLogin()
        }

        step("Each profile keeps its server") {
            profiles.open()
            for name in [first, second] {
                XCTAssertTrue(profiles.details(of: name).contains { $0.contains("api.netbird.io") },
                              "\(name) lost its server")
            }
        }
        markPassed()
    }

    /// LOGIN-S03 — Switch to a newly created profile.
    ///
    /// Creates a profile without a setup key, checks that creating it does not
    /// make it active, switches to it, and — on a device — checks that its
    /// first connect asks for a login, because the new profile has not signed
    /// in yet. The login itself is cancelled: the IdP page is out of a test's
    /// reach.
    ///
    /// The plan starts from a reset app (only "default", "No Additional
    /// Profiles"); the test runs against the unmodified app and cannot reset
    /// it, so it works from whatever profiles the device has.
    func testS03_switchToNewlyCreatedProfile() {
        let profile = newProfileName()

        step("Create \(profile) on NetBird Cloud, without a setup key") {
            profiles.open()
            profiles.create(profile)

            let details = profiles.details(of: profile)
            XCTAssertTrue(details.contains { $0.contains("api.netbird.io") },
                          "the new row does not show the NetBird Cloud server: \(details)")
            XCTAssertFalse(details.contains { $0.contains("@") },
                           "a profile that never signed in shows an account: \(details)")
            XCTAssertEqual(profiles.activeProfileName, startingProfile,
                           "creating a profile changed the active one")
        }

        step("Switch to \(profile)") {
            profiles.switchTo(profile, checkingMessage: true)
            XCTAssertNotNil(profiles.row(startingProfile),
                            "\(startingProfile) did not move to All Profiles")
        }

        step("The Connection tab shows \(profile)") {
            TabBar(app: app).open("Connection")
            XCTAssertTrue(connection.badge(profile).waitForExistence(timeout: 5),
                          "the profile badge does not read \(profile)")
        }
        screenshot("Switched to \(profile)")

        // Connect does nothing in the Simulator: VPN configurations cannot be
        // saved there.
        if !isSimulator {
            step("Connect asks for a login, which is cancelled") {
                XCTAssertTrue(connectExpectingLogin(), "connecting a new profile did not ask for a login within 30 s")
                screenshot("Sign-in asked for \(profile)")
                cancelSignIn()
                XCTAssertNotEqual(connection.state, "Connected",
                                  "the VPN connected without a login")
            }
        }

        markPassed()
    }
}
