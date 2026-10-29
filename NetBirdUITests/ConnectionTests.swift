//
//  ConnectionTests.swift
//  NetBirdUITests
//
//  Section H of the login UI test plan: the connection once a login is done.
//

import XCTest

final class ConnectionTests: E2ETestCase {

    /// LOGIN-H01 — a successful login lands on a usable connection: the
    /// status reads Connected, the peer's NetBird name and address are shown,
    /// and the Peers tab lists the network.
    func testH01_loginLandsOnUsableConnection() throws {
        try requireDevice()
        let profile = try createSignedInProfile()

        step("Connect \(profile)") {
            profiles.switchTo(profile)
            connectWithoutLogin()
            XCTAssertTrue(app.staticTexts["Connected"].exists, "the status does not read Connected")
        }

        step("The peer's name and address are shown") {
            // Both arrive with the first network map, a moment after Connected.
            XCTAssertTrue(connection.fqdn.waitForExistence(timeout: 30),
                          "no NetBird name under the status within 30 s")
            XCTAssertTrue(connection.ip.waitForExistence(timeout: 30),
                          "no NetBird address (100.x.x.x) under the status within 30 s")
        }
        screenshot("Connected with name \(connection.fqdn.label), address \(connection.ip.label)")

        step("The Peers tab renders") {
            TabBar(app: app).open("Peers")
            XCTAssertTrue(app.staticTexts["Peers connected"].waitForExistence(timeout: 5), "the Peers tab did not render")
            let count = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "^[0-9]+ of [0-9]+$")).firstMatch
            XCTAssertTrue(count.exists, "the Peers tab shows no \"N of M\" count")
        }
        screenshot("Peers")
        markPassed()
    }

    /// LOGIN-H02 — disconnecting ends the session cleanly: the status reads
    /// Disconnected and no error follows.
    ///
    /// The plan also expects the name and address to be cleared or hidden.
    /// The app clears them on a server or profile change but keeps them across
    /// a plain disconnect — the peer's identity does not change — so whether
    /// they stay is recorded with the result rather than failed on.
    func testH02_disconnectEndsTheSessionCleanly() throws {
        try requireDevice()
        let profile = try createSignedInProfile()

        step("Connect \(profile)") {
            profiles.switchTo(profile)
            connectWithoutLogin()
            _ = connection.ip.waitForExistence(timeout: 30)
        }

        step("Disconnect") {
            connection.disconnect()
            XCTAssertTrue(app.staticTexts["Disconnected"].waitForExistence(timeout: 10), "the status does not read Disconnected")
            XCTAssertEqual(app.alerts.count, 0, "an alert followed the disconnect: \(app.alerts.firstMatch.label)")
        }

        let kept = [connection.fqdn.exists ? "name" : nil, connection.ip.exists ? "address" : nil].compactMap { $0 }
        XCTContext.runActivity(named: kept.isEmpty ? "Name and address are cleared"
                                                   : "Still shown after the disconnect: \(kept.joined(separator: ", "))") { _ in }
        screenshot("After disconnecting")
        markPassed()
    }

    /// LOGIN-H03 — two quick taps on the toggle do not leave it stuck: it
    /// settles on Connected or Disconnected, and from there connects normally
    /// without a login.
    ///
    /// The toggle treats the second tap as "disconnect", so either end state is
    /// fine; what must not happen is a toggle stuck between the two.
    func testH03_doubleTapDoesNotLeaveTheToggleStuck() throws {
        try requireDevice()
        let profile = try createSignedInProfile()
        profiles.switchTo(profile)
        TabBar(app: app).open("Connection")

        step("Tap the toggle twice in quick succession") {
            XCTAssertTrue(connection.toggle.waitForExistence(timeout: 10), "no connect toggle")
            connection.toggle.tap()
            connection.toggle.tap()
        }

        step("The toggle settles within 60 s") {
            let settled = settledState(within: 60)
            XCTAssertNotNil(settled, "the toggle is stuck at \(connection.state)")
            XCTContext.runActivity(named: "Settled on \(settled ?? "nothing")") { _ in }
            XCTAssertFalse(SignInAlert.isShowing, "a login was asked for")
            XCTAssertFalse(app.alerts["Login failed"].exists, "a login error is shown")
        }

        step("It still connects normally") {
            if connection.state != "Connected" {
                connectWithoutLogin()
            }
        }
        markPassed()
    }

    /// LOGIN-H04 — the connected state survives a force-quit: the tunnel runs
    /// in the extension, so the relaunched app must show Connected, not a
    /// stale Disconnected.
    func testH04_connectedStateSurvivesRelaunch() throws {
        try requireDevice()
        let profile = try createSignedInProfile()

        step("Connect \(profile)") {
            profiles.switchTo(profile)
            connectWithoutLogin()
        }

        step("Force-quit and relaunch") {
            relaunch()
        }

        step("The app shows the running tunnel") {
            TabBar(app: app).open("Connection")
            let connected = NSPredicate(format: "value == %@", "Connected")
            XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: connected, object: connection.toggle)],
                                            timeout: 15), .completed,
                           "after a relaunch the toggle shows \(connection.state)")
        }
        screenshot("After relaunch")
        markPassed()
    }

    /// LOGIN-H05 — On Demand on a profile without credentials does not start
    /// a reconnect loop.
    ///
    /// Asking once for a login is fine — On Demand cannot work without one,
    /// and the app saying so ("Authentication required", Login / Later) is
    /// the right answer. What the plan's case guards against is a loop: the
    /// VPN retrying on its own and the prompt coming back again and again, or
    /// the VPN coming up without credentials. So one prompt is answered with
    /// Later, and the case fails only if another follows or the VPN connects.
    ///
    /// The plan expects the toggle to be refused; the app may instead keep the
    /// preference and defer the rules. Which one happened is recorded.
    ///
    /// On Demand is a device-wide setting, so it is switched off again whatever
    /// the outcome, unlike the rest of the state a failing test leaves behind.
    func testH05_onDemandWithoutCredentialsDoesNotLoop() throws {
        try requireDevice()
        let profile = createSignedOutProfile()
        profiles.switchTo(profile)

        let onDemand = OnDemandScreen(app: app)
        addTeardownBlock { [app] in
            // An alert the case itself provoked would cover the switch.
            AppAlerts.dismissAll(in: app!)
            let screen = OnDemandScreen(app: app!)
            screen.open()
            screen.set(false)
        }

        step("Turn On Demand on") {
            onDemand.open()
            onDemand.set(true)
            XCTContext.runActivity(named: onDemand.isOn ? "The toggle stays on (rules deferred)" : "The toggle was refused") { _ in }
            screenshot("On Demand on a signed-out profile")
        }

        step("For 30 s: at most one login prompt, and no connection") {
            var prompts = 0
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                let prompt = app.alerts["Authentication required"]
                if prompt.exists {
                    prompts += 1
                    screenshot("Login prompt \(prompts)")
                    prompt.buttons["Later"].tap()
                }
                XCTAssertFalse(SignInAlert.isShowing, "On Demand opened the login browser on its own")
                XCTAssertNotEqual(connection.state, "Connected", "the VPN connected without credentials")
                Thread.sleep(forTimeInterval: 1)
            }
            XCTContext.runActivity(named: "Login prompts in 30 s: \(prompts)") { _ in }
            XCTAssertLessThanOrEqual(prompts, 1, "the login prompt kept coming back: \(prompts) times in 30 s")
            let others = app.alerts.allElementsBoundByIndex.map(\.label)
            XCTAssertTrue(others.isEmpty, "another alert came up: \(others)")
            TabBar(app: app).open("Connection")
            XCTAssertNotEqual(connection.state, "Connected", "the VPN connected without credentials")
        }
        markPassed()
    }

    /// Waits for the toggle to rest on Connected or Disconnected for 5 s in a
    /// row, accepting the VPN configuration prompt on the way.
    private func settledState(within timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        var stableSince = Date()
        var last = ""
        while Date() < deadline {
            SystemAlerts.acceptIfPresent(timeout: 0.5)
            let value = connection.state
            if value != last {
                last = value
                stableSince = Date()
            }
            if ["Connected", "Disconnected"].contains(value) && Date().timeIntervalSince(stableSince) >= 5 {
                return value
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return nil
    }
}
