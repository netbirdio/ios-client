//
//  SetupKeyAuthTests.swift
//  NetBirdUITests
//
//  E2E-001: setup-key login — the iOS counterpart of the Android
//  SetupKeyAuthTest. A fresh profile is created through the Profiles UI and
//  logged in to NetBird Cloud with the setup key from NB_SETUP_KEY; the
//  login is proven by connecting on that profile without being asked to
//  sign in.
//

import XCTest

final class SetupKeyAuthTests: E2ETestCase {

    func testLoginWithSetupKeyViaUi() throws {
        let setupKey = try TestSecrets.value("NB_SETUP_KEY")
        let profile = newProfileName()

        step("Create \(profile) with the setup key") {
            profiles.open()
            profiles.create(profile, setupKey: setupKey)
        }

        step("Switch to \(profile)") {
            profiles.switchTo(profile)
        }

        step("Connect") {
            connection.connect()
            XCTAssertTrue(app.staticTexts["Connected"].waitForExistence(timeout: 5), "the status does not read Connected")
            XCTAssertFalse(app.alerts["Login failed"].exists, "a login error is shown")
            XCTAssertFalse(SignInAlert.isShowing, "a setup-key profile was asked to sign in")
        }

        screenshot("Connected on \(profile)")
        markPassed()
    }
}
