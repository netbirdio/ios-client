//
//  AppLaunch.swift
//  NetBirdUITests
//
//  Brings the unmodified app from a cold launch to its main screen, the way a
//  user would: answer the system prompts and pass the one-time onboarding.
//

import XCTest

enum AppLaunch {

    /// Launches the app and returns once the tab bar is on screen.
    @discardableResult
    static func toMainScreen(_ app: XCUIApplication = XCUIApplication(),
                             file: StaticString = #filePath, line: UInt = #line) -> XCUIApplication {
        app.launch()

        let tabBar = app.tabBars.firstMatch
        let onboardingContinue = app.buttons["Continue"]
        let deadline = Date().addingTimeInterval(30)

        // The notification prompt and the onboarding screen can appear in either
        // order, or not at all on a device that has run the app before.
        while !tabBar.exists && Date() < deadline {
            if SystemAlerts.acceptIfPresent() {
                continue
            }
            if onboardingContinue.exists && onboardingContinue.isHittable {
                onboardingContinue.tap()
                continue
            }
            _ = tabBar.waitForExistence(timeout: 1)
        }

        XCTAssertTrue(tabBar.exists, "the tab bar did not appear after launch", file: file, line: line)
        return app
    }
}

/// System alerts owned by SpringBoard. Buttons are matched by label in the
/// languages a test device is likely to use.
enum SystemAlerts {

    static let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    private static let acceptLabels: Set<String> = ["Allow", "OK", "Разрешить", "Дозволити"]

    /// Accepts a permission prompt (notifications, VPN configuration) if one
    /// is showing. Only a button with a known accepting label is tapped:
    /// guessing by position would hit Continue in the SSO sign-in alert and
    /// open the browser.
    @discardableResult
    static func acceptIfPresent(timeout: TimeInterval = 1) -> Bool {
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: timeout), !SignInAlert.isShowing else { return false }
        // The alert can go away at any moment — dismissed by hand, or replaced
        // by the next prompt — and querying a vanished alert fails the test.
        // A snapshot throws instead, and a tap at its coordinates cannot fail.
        guard let snapshot = try? alert.snapshot(), let button = findButton(in: snapshot) else {
            return false
        }
        springboard.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: button.frame.midX, dy: button.frame.midY))
            .tap()
        return true
    }

    private static func findButton(in snapshot: XCUIElementSnapshot) -> XCUIElementSnapshot? {
        for child in snapshot.children {
            if child.elementType == .button && acceptLabels.contains(child.label) { return child }
            if let found = findButton(in: child) { return found }
        }
        return nil
    }
}

/// The alert iOS shows before the SSO login opens in the browser:
/// "“NetBird” Wants to Use "<domain>" to Sign In" — Cancel / Continue. The
/// test cannot reach the IdP page behind it, so this alert is how a test sees
/// that the app asked for a login.
enum SignInAlert {

    private static let cancelLabels: Set<String> = ["Cancel", "Отменить", "Скасувати"]
    private static let continueLabels: Set<String> = ["Continue", "Продолжить", "Продовжити"]

    private static var alert: XCUIElement { SystemAlerts.springboard.alerts.firstMatch }

    private static func button(_ labels: Set<String>) -> XCUIElement? {
        alert.buttons.allElementsBoundByIndex.first { labels.contains($0.label) }
    }

    static var isShowing: Bool {
        alert.exists && button(cancelLabels) != nil && button(continueLabels) != nil
    }

    static func waitForAppearance(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if isShowing {
                return true
            }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline
        return false
    }

    static func cancel(file: StaticString = #filePath, line: UInt = #line) {
        guard let cancel = button(cancelLabels) else {
            XCTFail("no sign-in alert to cancel", file: file, line: line)
            return
        }
        cancel.tap()
        let gone = NSPredicate(format: "exists == false")
        _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: gone, object: alert)], timeout: 5)
    }
}
