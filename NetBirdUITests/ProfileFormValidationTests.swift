//
//  ProfileFormValidationTests.swift
//  NetBirdUITests
//
//  Section D of the login test plan, cases D02–D05: the New Profile sheet
//  rejects malformed input on the device, before anything is sent to a
//  server, and a rejected profile is not left behind.
//
//  The plan names the Server screen; the same fields and checks sit in the
//  New Profile sheet, which lets the tests leave the "default" profile alone.
//  None of these cases needs a network, an account or a VPN.
//

import XCTest

final class ProfileFormValidationTests: E2ETestCase {

    private let invalidURL = "Invalid URL format"
    private let invalidKey = "Invalid setup key format"

    /// LOGIN-D02 — a setup key that is not a UUID is rejected locally.
    func testD02_malformedSetupKeyIsRejected() {
        let profile = newProfileName()
        let sheet = openSheet()

        sheet.fill(name: profile, server: "https://api.netbird.io", setupKey: "not-a-key")
        sheet.submit()

        XCTAssertTrue(sheet.waitForMessage(invalidKey), "no setup key error")
        XCTAssertFalse(sheet.showsMessage(invalidURL), "a valid URL was reported as invalid")
        expectRejected(profile, sheet)
    }

    /// LOGIN-D03 — a server URL that is not a URL is rejected locally.
    func testD03_malformedServerURLIsRejected() {
        let profile = newProfileName()
        let sheet = openSheet()

        sheet.fill(name: profile, server: "not a url", setupKey: UUID().uuidString)
        sheet.submit()

        XCTAssertTrue(sheet.waitForMessage(invalidURL), "no URL error")
        XCTAssertFalse(sheet.showsMessage(invalidKey), "a well-formed setup key was reported as invalid")
        expectRejected(profile, sheet)
    }

    /// LOGIN-D04 — with both fields wrong, both errors are shown at once.
    func testD04_bothFieldsInvalid() {
        let profile = newProfileName()
        let sheet = openSheet()

        sheet.fill(name: profile, server: "not a url", setupKey: "not-a-key")
        sheet.submit()

        XCTAssertTrue(sheet.waitForMessage(invalidURL), "no URL error")
        XCTAssertTrue(sheet.waitForMessage(invalidKey), "no setup key error")
        expectRejected(profile, sheet)
    }

    /// LOGIN-D05 — submitting an empty sheet. In the New Profile sheet an
    /// empty server means NetBird Cloud and an empty key means no key, so the
    /// field that must be filled is the name: the sheet refuses it with an
    /// alert and stays usable.
    func testD05_emptySheetIsRejected() {
        let sheet = openSheet()

        sheet.submit()

        let alert = app.alerts["Invalid Profile Name"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "an empty profile name was accepted")
        XCTAssertTrue(alert.staticTexts["Only letters, numbers, underscores and hyphens are allowed."].exists,
                      "the alert does not explain the allowed characters")
        screenshot("Empty sheet refused")
        alert.buttons["OK"].tap()

        XCTAssertTrue(sheet.navigationBar.exists, "the sheet closed after the alert")
        XCTAssertTrue(sheet.createButton.isEnabled, "the sheet is not usable after the alert")
        sheet.cancel()
        markPassed()
    }

    /// LOGIN-D06 — a well-formed key the server does not know is rejected by
    /// the server: the sheet shows the server's answer under the key and no
    /// profile is created. Needs the network.
    func testD06_unknownSetupKeyIsRejectedByServer() {
        let profile = newProfileName()
        let sheet = openSheet()

        // A random UUID: well-formed, but no account issued it.
        sheet.fill(name: profile, setupKey: UUID().uuidString)
        sheet.submit()

        let message = sheet.waitForMessage(startingWith: "Review the setup key", timeout: 60)
        XCTAssertNotNil(message, "the server's rejection of the key is not shown; the sheet shows: "
                        + sheet.visibleTexts.joined(separator: " | "))
        expectRejected(profile, sheet)
    }

    // MARK: - Helpers

    private func openSheet() -> NewProfileSheet {
        profiles.open()
        return profiles.openNewProfileSheet()
    }

    /// After a local validation error: the sheet stays open and usable, and
    /// once it is closed the rejected profile is not in the list.
    private func expectRejected(_ profile: String, _ sheet: NewProfileSheet,
                                file: StaticString = #filePath, line: UInt = #line) {
        screenshot("Rejected input")
        XCTAssertTrue(sheet.navigationBar.exists, "the sheet closed despite the error", file: file, line: line)
        XCTAssertTrue(sheet.createButton.waitForExistence(timeout: 5) && sheet.createButton.isEnabled,
                      "the sheet did not become usable again", file: file, line: line)
        sheet.cancel()
        XCTAssertNil(profiles.row(profile, timeout: 1), "the rejected profile \(profile) was left in the list",
                     file: file, line: line)
        markPassed()
    }
}
