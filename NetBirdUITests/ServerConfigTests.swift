//
//  ServerConfigTests.swift
//  NetBirdUITests
//
//  Section E of the login test plan: the management server a profile is
//  configured with. As in section D, the New Profile sheet stands in for the
//  Server screen so the "default" profile is left alone.
//
//  LOGIN-E02 (a URL with an explicit port round-trips) is not here: a profile
//  is only saved once its server answers, no reachable test server listens on
//  a non-default port, and for NetBird Cloud the app shows ":443" whether or
//  not it was typed — so the UI cannot tell a kept port from an added one.
//  The round-trip belongs to unit coverage, as the plan notes.
//

import XCTest

final class ServerConfigTests: E2ETestCase {

    /// LOGIN-E01 — the server URL survives a force-quit and relaunch.
    func testE01_serverURLPersistsAcrossRelaunch() {
        let profile = newProfileName()

        step("Create \(profile) on NetBird Cloud") {
            profiles.open()
            profiles.create(profile)
            XCTAssertTrue(profiles.details(of: profile).contains { $0.contains("api.netbird.io") },
                          "the new row does not show the server")
        }

        step("Force-quit and relaunch") {
            relaunch()
        }

        step("The profile still shows its server") {
            profiles.open()
            let details = profiles.details(of: profile)
            XCTAssertTrue(details.contains { $0.contains("api.netbird.io") },
                          "after a relaunch the row shows: \(details)")
        }
        screenshot("After relaunch")
        markPassed()
    }

    /// LOGIN-E03 — a server that cannot be reached is reported, not silently
    /// accepted. The SDK gives up only after its own timeout, so the case
    /// allows three minutes.
    func testE03_unreachableServerIsReported() {
        let profile = newProfileName()
        profiles.open()
        let sheet = profiles.openNewProfileSheet()

        // A private address nothing answers on: the connection hangs until
        // the SDK's timeout instead of failing at once.
        sheet.fill(name: profile, server: "https://10.255.255.1")
        sheet.submit()

        let message = sheet.waitForMessage(startingWith: "Review the URL", timeout: 180)
            ?? sheet.visibleTexts.first { $0.localizedCaseInsensitiveContains("error") || $0.contains("deadline") }
        XCTAssertNotNil(message, "an unreachable server was not reported within 3 minutes; the sheet shows: "
                        + sheet.visibleTexts.joined(separator: " | "))
        screenshot("Unreachable server")

        XCTAssertTrue(sheet.navigationBar.exists, "the sheet closed as if the server had been accepted")
        sheet.cancel()
        XCTAssertNil(profiles.row(profile, timeout: 1), "a profile with an unreachable server was saved")
        markPassed()
    }
}
