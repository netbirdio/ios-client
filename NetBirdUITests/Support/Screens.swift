//
//  Screens.swift
//  NetBirdUITests
//
//  The app's screens as a test drives them. Elements are found by what a user
//  sees — tab names, button titles, screen titles — because the tests run
//  against the unmodified app.
//

import XCTest

/// Values the CI passes in through the test runner's environment
/// (TEST_RUNNER_<NAME> on the xcodebuild command line).
enum TestSecrets {
    static func value(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let value = ProcessInfo.processInfo.environment[name] ?? ""
        return try XCTUnwrap(value.isEmpty ? nil : value, "\(name) is not set for this run", file: file, line: line)
    }
}

struct TabBar {
    let app: XCUIApplication

    func open(_ name: String) {
        let button = app.tabBars.firstMatch.buttons[name]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "no \(name) tab")
        button.tap()
    }
}

struct ConnectionScreen {
    let app: XCUIApplication

    /// The connect/disconnect toggle; its value is the connection state.
    var toggle: XCUIElement {
        app.descendants(matching: .any)["VPN Connection"]
    }

    /// The toggle's state, or "" when the Connection tab is not on screen.
    /// Reading `toggle.value` directly fails the test when the toggle is
    /// not there, for instance while another tab or an alert is up.
    var state: String {
        toggle.exists ? (toggle.value as? String ?? "") : ""
    }

    /// The tunnel can take well over a minute to come up on a busy account,
    /// so a connect is given three minutes before it counts as failed.
    func connect(timeout: TimeInterval = 180) {
        tapToggle()
        waitForState("Connected", timeout: timeout, acceptingPrompts: true)
    }

    /// Taps the toggle on the Connection tab and makes sure the tap was taken.
    ///
    /// Right after a profile switch the toggle is locked for a few seconds
    /// while the old connection winds down, and a tap in that window is
    /// dropped without a trace. So the tap waits for Disconnecting to pass,
    /// and is repeated when nothing reacts to it: the state leaving
    /// Disconnected, the sign-in alert, or a system prompt. The last retry
    /// first switches tabs, so the toggle is redrawn with its current lock.
    /// How many taps it took is recorded with the result.
    func tapToggle() {
        TabBar(app: app).open("Connection")
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "no connect toggle")
        let before = toggle.value as? String ?? ""
        waitWhileDisconnecting()

        for attempt in 1...4 {
            if attempt == 4 {
                TabBar(app: app).open("Peers")
                TabBar(app: app).open("Connection")
            }
            // Right after a profile switch the app can bring back the
            // Settings tab by itself while the tap waits.
            if !toggle.exists {
                TabBar(app: app).open("Connection")
                guard toggle.waitForExistence(timeout: 10) else {
                    XCTFail("no connect toggle")
                    return
                }
            }
            toggle.tap()
            if reacted(from: before, within: 8) {
                if attempt > 1 {
                    XCTContext.runActivity(named: "The toggle took the tap only on attempt \(attempt)") { _ in }
                }
                return
            }
        }
        XCTContext.runActivity(named: "The toggle did not react to 4 taps") { _ in }
    }

    private func waitWhileDisconnecting(timeout: TimeInterval = 15) {
        let deadline = Date().addingTimeInterval(timeout)
        while (toggle.value as? String) == "Disconnecting" && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
        }
        // The lock outlasts the state by up to the app's 3 s timer.
        Thread.sleep(forTimeInterval: 3)
    }

    /// Whether anything answered a tap: the state moved, or a prompt came up.
    private func reacted(from before: String, within seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let now = toggle.value as? String ?? ""
            if now != before && now != "" {
                return true
            }
            if SignInAlert.isShowing || SystemAlerts.springboard.alerts.firstMatch.exists || app.alerts.firstMatch.exists {
                return true
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    /// The peer's NetBird name under the status once connected, e.g.
    /// "iphone-1a2b.netbird.cloud": a host name of at least three labels.
    var fqdn: XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "^[A-Za-z0-9-]*[A-Za-z][A-Za-z0-9-]*(\\.[A-Za-z0-9-]+){2,}$")).firstMatch
    }

    /// The peer's NetBird address, from the 100.64.0.0/10 range NetBird assigns.
    var ip: XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "^100\\.[0-9]+\\.[0-9]+\\.[0-9]+.*$")).firstMatch
    }

    /// The profile badge above the toggle; its label is the active profile's name.
    func badge(_ name: String) -> XCUIElement {
        app.buttons[name]
    }

    func disconnect(timeout: TimeInterval = 30) {
        TabBar(app: app).open("Connection")
        guard state != "Disconnected" else { return }
        // Right after Connected the toggle is still locked by the connect,
        // so the tap goes through the same retry as a connect.
        tapToggle()
        // With On Demand on, the app asks first, since iOS would reconnect
        // right away otherwise.
        let onDemand = app.alerts["VPN On Demand Active"]
        if onDemand.waitForExistence(timeout: 2) {
            onDemand.buttons["Disable & Disconnect"].tap()
        }
        waitForState("Disconnected", timeout: timeout, acceptingPrompts: false)
    }

    /// Waits for the toggle to report a state. The first connect after an
    /// install asks to add the VPN configuration; that prompt is accepted
    /// while waiting.
    private func waitForState(_ state: String, timeout: TimeInterval, acceptingPrompts: Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (toggle.value as? String) == state {
                return
            }
            if SignInAlert.isShowing {
                XCTFail("the app asked to sign in while waiting for \(state)")
                return
            }
            if acceptingPrompts && SystemAlerts.acceptIfPresent(timeout: 0.5) {
                continue
            }
            Thread.sleep(forTimeInterval: 1)
        }
        XCTFail("the connection did not reach \(state) within \(Int(timeout)) s, it shows \(toggle.value as? String ?? "nothing")")
    }
}

struct ProfilesScreen {
    let app: XCUIApplication

    static let testProfilePrefix = "e2e-"

    /// Opens Settings → Profiles.
    @discardableResult
    func open() -> ProfilesScreen {
        if app.navigationBars["Profiles"].exists {
            return self
        }
        TabBar(app: app).open("Settings")
        // The Settings tab keeps its navigation stack: if Profiles was opened
        // earlier in this launch, the tab comes back on it.
        let profilesBar = app.navigationBars["Profiles"]
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Profiles'")).firstMatch
        let deadline = Date().addingTimeInterval(5)
        while !profilesBar.exists && !row.exists && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.3)
        }
        if profilesBar.exists {
            return self
        }
        // Back on some other screen pushed inside Settings: return to its root.
        if !row.exists && !app.navigationBars["Settings"].exists {
            let back = app.navigationBars.buttons.element(boundBy: 0)
            if back.exists {
                back.tap()
                _ = row.waitForExistence(timeout: 3)
            }
        }
        // The app hides the row when an MDM policy disables profiles, so a
        // missing row on the Settings screen itself is the policy, not a
        // broken screen.
        if !row.exists && app.navigationBars["Settings"].exists {
            XCTFail("no Profiles row in Settings — profile management is most likely disabled by an MDM policy on this "
                    + "device (Settings → General → VPN & Device Management). Test devices must not be managed.")
            return self
        }
        XCTAssertTrue(row.exists, "the Settings tab shows neither its main screen nor Profiles")
        row.tap()
        XCTAssertTrue(app.navigationBars["Profiles"].waitForExistence(timeout: 5), "the Profiles screen did not open")
        return self
    }

    /// A profile name as the list exposes it: alone as a text, or first in a
    /// row's combined label ("default", "e2e-1a2b, https://…").
    private func matches(_ name: String) -> NSPredicate {
        NSPredicate(format: "label == %@ OR label BEGINSWITH %@", name, name + ",")
    }

    /// The row of the active profile — the one cell with the green "Active"
    /// badge next to a name. The section header reads "Active" too, but holds
    /// nothing else.
    private var activeCell: XCUIElement? {
        app.cells.allElementsBoundByIndex.first { cell in
            cell.staticTexts["Active"].exists && cell.staticTexts.count > 1
        }
    }

    var activeProfileName: String? {
        activeCell?.staticTexts.allElementsBoundByIndex
            .map(\.label)
            .first { $0 != "Active" && !$0.hasPrefix("http") }
    }

    /// The row of a profile under All Profiles — only those can be switched
    /// to or removed. Nil if there is none within the timeout.
    func row(_ name: String, timeout: TimeInterval = 5) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let row = app.cells.containing(matches(name)).allElementsBoundByIndex
                .first { !$0.staticTexts["Active"].exists }
            if let row {
                return row
            }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline
        return nil
    }

    /// Everything a profile's row shows: the name, the server URL and, once
    /// the profile has signed in with SSO, the account email. Works for the
    /// active row and for the others, which expose it as one combined label.
    func details(of name: String) -> [String] {
        let cell = name == activeProfileName
            ? activeCell
            : row(name, timeout: 2)
        guard let cell else { return [] }
        let labels = (cell.staticTexts.allElementsBoundByIndex + cell.buttons.allElementsBoundByIndex).map(\.label)
        let parts = labels.flatMap { $0.components(separatedBy: ", ") }
        var seen = Set<String>()
        return parts.filter { !$0.isEmpty && $0 != "Active" && seen.insert($0).inserted }
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() {
                return true
            }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline
        return false
    }

    /// Creates a profile on the default server (NetBird Cloud) through the New
    /// Profile sheet. With a setup key the profile is logged in right away;
    /// without one it is created signed out, and its first connect asks for
    /// an SSO login.
    func create(_ name: String, setupKey: String? = nil, timeout: TimeInterval = 60) {
        let sheet = openNewProfileSheet()
        sheet.fill(name: name, setupKey: setupKey)
        sheet.submit()

        // The sheet closes itself once the server accepted the profile; on an
        // error it stays open with the message under the field.
        if !sheet.waitUntilClosed(timeout: timeout) {
            XCTFail("the profile was not created within \(Int(timeout)) s; the sheet shows: \(sheet.visibleTexts.joined(separator: " | "))")
        }
        XCTAssertNotNil(row(name), "\(name) is not in the profile list")
    }

    func openNewProfileSheet() -> NewProfileSheet {
        let add = app.navigationBars["Profiles"].buttons["Add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5), "no add button on the Profiles screen")
        let sheet = NewProfileSheet(app: app)
        // A notification banner over the navigation bar takes the tap.
        for _ in 1...2 {
            // A tap on a banner opens it, and can leave a Face ID prompt.
            Banner.waitUntilGone()
            add.tap()
            if sheet.navigationBar.waitForExistence(timeout: 5) { return sheet }
        }
        XCTFail("the New Profile sheet did not open")
        return sheet
    }

    /// Switches through the row and its confirmation alert. With
    /// `checkingMessage` the alert's text is checked against the wording the
    /// user is shown.
    func switchTo(_ name: String, checkingMessage: Bool = false) {
        guard activeProfileName != name else { return }
        guard let target = row(name) else {
            XCTFail("no \(name) profile to switch to")
            return
        }
        target.tap()
        let alert = app.alerts["Switch Profile"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "no Switch Profile confirmation")
        if checkingMessage {
            let expected = "VPN will be disconnected to switch to \u{00AB}\(name)\u{00BB}. Continue?"
            XCTAssertTrue(alert.staticTexts[expected].exists,
                          "the Switch Profile alert does not read: \(expected)")
        }
        alert.buttons["Switch"].tap()
        XCTAssertTrue(waitUntil(timeout: 10) { activeProfileName == name }, "\(name) did not become the active profile")
    }

    /// Taps a profile's row and answers Cancel in the confirmation: nothing
    /// may change.
    func cancelSwitch(to name: String) {
        guard let target = row(name) else {
            XCTFail("no \(name) profile")
            return
        }
        target.tap()
        let alert = app.alerts["Switch Profile"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "no Switch Profile confirmation")
        alert.buttons["Cancel"].tap()
        let gone = NSPredicate(format: "exists == false")
        _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: gone, object: alert)], timeout: 5)
    }

    /// Logs a profile out through its row's swipe action. The app offers
    /// Logout only on profiles that are not active, so switch away first.
    /// With `checkingMessage` the confirmation text is checked too.
    func logout(_ name: String, checkingMessage: Bool = false) {
        guard let target = row(name) else {
            XCTFail("no \(name) profile to log out")
            return
        }
        target.swipeLeft()
        let action = app.buttons["Logout"]
        XCTAssertTrue(action.waitForExistence(timeout: 3), "no Logout action on \(name)")
        action.tap()

        let alert = app.alerts["Logout from Profile"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "no Logout from Profile confirmation")
        if checkingMessage {
            let expected = "You will need to re-authenticate to use profile \u{00AB}\(name)\u{00BB} again."
            XCTAssertTrue(alert.staticTexts[expected].exists, "the Logout alert does not read: \(expected)")
        }
        alert.buttons["Logout"].tap()

        let gone = NSPredicate(format: "exists == false")
        _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: gone, object: alert)], timeout: 5)
        XCTAssertFalse(app.alerts["Error"].waitForExistence(timeout: 2),
                       "logging \(name) out failed: \(app.alerts["Error"].staticTexts.allElementsBoundByIndex.map(\.label))")
    }

    /// Removes a profile that is not the active one; the app offers no Remove
    /// on the active profile.
    func remove(_ name: String) {
        guard let target = row(name, timeout: 2) else { return }
        let remove = app.buttons["Remove"]
        for _ in 1...2 where !remove.exists {
            Banner.waitUntilGone()
            target.swipeLeft()
            _ = remove.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(remove.exists, "no Remove action on \(name)")
        remove.tap()
        let alert = app.alerts["Remove Profile"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "no Remove Profile confirmation")
        alert.buttons["Remove"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { row(name, timeout: 0) == nil }, "\(name) is still in the profile list")
    }

    /// Profiles the earlier runs left behind, for instance after a failure.
    var leftoverTestProfiles: [String] {
        let labels = (app.staticTexts.allElementsBoundByIndex + app.buttons.allElementsBoundByIndex).map(\.label)
        let names = labels
            .map { String($0.split(separator: ",").first ?? "") }
            .filter { $0.hasPrefix(Self.testProfilePrefix) }
        return Array(Set(names)).sorted()
    }
}

/// The New Profile sheet: a name, a server URL (empty means NetBird Cloud) and
/// an optional setup key.
struct NewProfileSheet {
    let app: XCUIApplication

    var navigationBar: XCUIElement { app.navigationBars["New Profile"] }
    var createButton: XCUIElement { navigationBar.buttons["Create"] }

    var nameField: XCUIElement { textField(placeholder: "Profile name") }
    var serverField: XCUIElement { textField(placeholder: "https://api.netbird.io") }
    // The placeholder is an example key; it is the only stable handle the field has.
    var setupKeyField: XCUIElement { textField(placeholder: "0EF79C2F-DEE1-419B-BFC8-1BF529332998") }

    /// Types into the fields; nil leaves a field as it is. A setup key opens
    /// the "Add this device with a setup key" section first.
    func fill(name: String? = nil, server: String? = nil, setupKey: String? = nil) {
        if let name {
            type(name, into: nameField, "profile name")
        }
        if let server {
            type(server, into: serverField, "server")
        }
        if let setupKey {
            if !setupKeyField.exists {
                app.buttons["Add this device with a setup key"].tap()
            }
            type(setupKey, into: setupKeyField, "setup key")
        }
    }

    func submit() {
        // Create sits in the navigation bar, right under where banners show.
        Banner.waitUntilGone()
        createButton.tap()
    }

    func cancel() {
        Banner.waitUntilGone()
        navigationBar.buttons["Cancel"].tap()
        XCTAssertTrue(waitUntilClosed(timeout: 5), "the New Profile sheet did not close")
    }

    func waitUntilClosed(timeout: TimeInterval) -> Bool {
        let closed = NSPredicate(format: "exists == false")
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: closed, object: navigationBar)], timeout: timeout) == .completed
    }

    /// Waits for a message to be shown in the sheet, e.g. a field error.
    func waitForMessage(_ text: String, timeout: TimeInterval = 5) -> Bool {
        app.staticTexts[text].waitForExistence(timeout: timeout)
    }

    func showsMessage(_ text: String) -> Bool {
        app.staticTexts[text].exists
    }

    /// Waits for a message that starts with the given text — server errors
    /// carry the SDK's own wording after a fixed lead.
    func waitForMessage(startingWith prefix: String, timeout: TimeInterval) -> String? {
        let message = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
        return message.waitForExistence(timeout: timeout) ? message.label : nil
    }

    var visibleTexts: [String] {
        app.staticTexts.allElementsBoundByIndex.map(\.label).filter { !$0.isEmpty }
    }

    private func type(_ text: String, into field: XCUIElement, _ what: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no \(what) field")
        field.tap()
        field.typeText(text)
    }

    private func textField(placeholder: String) -> XCUIElement {
        app.textFields.matching(NSPredicate(format: "placeholderValue == %@", placeholder)).firstMatch
    }
}

/// Settings → VPN On Demand.
struct OnDemandScreen {
    let app: XCUIApplication

    var toggle: XCUIElement { app.switches["VPN On Demand"] }

    var isOn: Bool { (toggle.value as? String) == "1" }

    @discardableResult
    func open() -> OnDemandScreen {
        if app.navigationBars["VPN On Demand"].exists {
            return self
        }
        TabBar(app: app).open("Settings")
        if app.navigationBars["Settings"].waitForExistence(timeout: 3) == false {
            // The tab came back on a pushed screen; go back to its root.
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        let row = app.buttons["VPN On Demand"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "no VPN On Demand row in Settings")
        row.tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "the VPN On Demand screen did not open")
        return self
    }

    func set(_ on: Bool) {
        guard isOn != on else { return }
        // A SwiftUI switch takes the tap on its knob, at the right edge.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let target = NSPredicate(format: "value == %@", on ? "1" : "0")
        _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: target, object: toggle)], timeout: 5)
    }
}

/// The app's own alerts — the ones it raises by itself, not in answer to a
/// test's tap. A test that finds one up before it starts closes it with the
/// alert's non-acting button, so a state left behind by an earlier test does
/// not block the screens this one needs.
enum AppAlerts {

    /// Buttons that close an alert without acting on it.
    private static let dismissLabels = ["Later", "OK", "Cancel", "Edit Rules"]

    /// Closes the app's alerts one after another; returns their titles.
    @discardableResult
    static func dismissAll(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) -> [String] {
        var closed: [String] = []
        for _ in 0..<5 {
            let alert = app.alerts.firstMatch
            guard alert.waitForExistence(timeout: 1) else { break }
            let title = alert.label
            guard let label = dismissLabels.first(where: { alert.buttons[$0].exists }) else {
                XCTFail("an alert with no way to close it is up: \(title)", file: file, line: line)
                break
            }
            alert.buttons[label].tap()
            closed.append(title)
        }
        return closed
    }
}

/// A notification banner at the top of the screen. It covers the navigation
/// bar for a few seconds and takes any tap aimed there.
enum Banner {
    static var element: XCUIElement {
        SystemAlerts.springboard.descendants(matching: .any)["NotificationShortLookView"]
    }

    static func waitUntilGone(timeout: TimeInterval = 10) {
        guard element.exists else { return }
        XCTContext.runActivity(named: "Wait for a notification banner to go away") { _ in
            let deadline = Date().addingTimeInterval(timeout)
            while element.exists && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
    }
}
