//
//  TabBarNavigationTests.swift
//  NetBirdUITests
//
//  SMOKE-001: every tab in the tab bar opens its screen. Needs no account,
//  no network and no VPN, so it is the first check that the device, the
//  signing and the test runner work at all.
//

import XCTest

final class TabBarNavigationTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = AppLaunch.toMainScreen()
    }

    func testSwitchesThroughAllTabs() {
        // Resources is hidden when an MDM policy disables networks.
        let resourcesShown = tab("Resources").exists

        open("Peers", showing: app.staticTexts["Peers connected"])
        if resourcesShown {
            open("Resources", showing: app.staticTexts["Resources connected"])
        }
        open("Settings", showing: app.navigationBars["Settings"])
        open("Connection", showing: nil)

        // And once more in reverse, so every tab is also left from another one.
        open("Settings", showing: app.navigationBars["Settings"])
        if resourcesShown {
            open("Resources", showing: app.staticTexts["Resources connected"])
        }
        open("Peers", showing: app.staticTexts["Peers connected"])
        open("Connection", showing: nil)
    }

    // MARK: - Helpers

    private func tab(_ name: String) -> XCUIElement {
        app.tabBars.firstMatch.buttons[name]
    }

    /// Taps a tab and checks that it became the selected one and that its
    /// screen shows the expected element. A screenshot of each screen is kept
    /// with the result.
    private func open(_ name: String, showing marker: XCUIElement?, file: StaticString = #filePath, line: UInt = #line) {
        XCTContext.runActivity(named: "Open the \(name) tab") { activity in
            let button = tab(name)
            XCTAssertTrue(button.waitForExistence(timeout: 5), "no \(name) tab", file: file, line: line)
            button.tap()

            let selected = NSPredicate(format: "isSelected == true")
            let result = XCTWaiter().wait(for: [expectation(for: selected, evaluatedWith: button)], timeout: 5)
            XCTAssertEqual(result, .completed, "the \(name) tab did not become selected", file: file, line: line)

            if let marker {
                XCTAssertTrue(marker.waitForExistence(timeout: 5), "the \(name) screen did not appear", file: file, line: line)
            }

            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "\(name) tab"
            screenshot.lifetime = .keepAlways
            activity.add(screenshot)
        }
    }
}
