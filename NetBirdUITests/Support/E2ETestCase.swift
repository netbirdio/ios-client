//
//  E2ETestCase.swift
//  NetBirdUITests
//
//  The base for tests that create profiles. Every profile a test creates is
//  named e2e-<random> and is removed again after a passing test. A failing
//  test leaves the device exactly as it is, so a developer can look at the
//  state over remote access while the run is held; the next run removes the
//  leftovers before it starts.
//

import XCTest

class E2ETestCase: XCTestCase {

    var app: XCUIApplication!
    var profiles: ProfilesScreen!
    var connection: ConnectionScreen!

    /// The profile that was active when the test started; restored on success.
    private(set) var startingProfile = "default"
    private var createdProfiles: [String] = []

    /// Set by `markPassed()` as a test's last step. XCTest's own
    /// testRun.hasSucceeded still reads false inside tearDown, so it cannot
    /// tell a pass from a failure there.
    private var passed = false

    /// Set when the test cancelled a sign-in, so cleanup waits for the late
    /// "Login failed" that follows (LOGIN-B01).
    private var cancelledLogin = false

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = AppLaunch.toMainScreen()
        profiles = ProfilesScreen(app: app)
        connection = ConnectionScreen(app: app)
        resetDeviceWideState()
        removeLeftovers()
        profiles.open()
        startingProfile = profiles.activeProfileName ?? startingProfile
    }

    override func tearDownWithError() throws {
        guard passed, !createdProfiles.isEmpty else { return }
        // The alert can come more than 10 s after the cancel.
        closeLoginFailed(waiting: cancelledLogin ? 15 : 0)
        connection.disconnect()
        profiles.open()
        profiles.switchTo(startingProfile)
        for name in createdProfiles {
            profiles.remove(name)
        }
    }

    /// A unique name for a profile this test creates, remembered for cleanup.
    func newProfileName() -> String {
        let name = ProfilesScreen.testProfilePrefix + String(UUID().uuidString.prefix(8)).lowercased()
        createdProfiles.append(name)
        return name
    }

    func markPassed() {
        passed = true
    }

    /// Runs a block as a named step, so the result shows the steps the way
    /// the test plan lists them.
    func step(_ name: String, _ block: () throws -> Void) rethrows {
        try XCTContext.runActivity(named: name) { _ in try block() }
    }

    /// A screenshot kept with the result whatever the outcome.
    func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Force-quits the app and launches it again, as a user swiping it away
    /// from the app switcher would.
    func relaunch() {
        app.terminate()
        app = AppLaunch.toMainScreen(app)
        profiles = ProfilesScreen(app: app)
        connection = ConnectionScreen(app: app)
    }

    /// Taps Connect and waits for the app to ask for an SSO login, accepting
    /// the VPN configuration prompt a first connect after an install shows.
    /// Returns whether the sign-in alert appeared; it is left on screen.
    @discardableResult
    func connectExpectingLogin(timeout: TimeInterval = 30) -> Bool {
        connection.tapToggle()
        let deadline = Date().addingTimeInterval(timeout)
        while !SignInAlert.isShowing && Date() < deadline {
            if connection.state == "Connected" {
                return false
            }
            // A "Login failed" from an earlier cancel that came late takes
            // the tap; close it and tap again.
            if closeLoginFailed() {
                connection.tapToggle()
                continue
            }
            SystemAlerts.acceptIfPresent(timeout: 1)
        }
        return SignInAlert.isShowing
    }

    /// Cancels the sign-in alert. The app then reports the cancel as a
    /// "Login failed" error — the known bug LOGIN-B01 is disabled for — and
    /// it can take several seconds to come. That alert would block the next
    /// tap, so it is waited for, recorded and closed here; B01 is the case
    /// that fails on it.
    func cancelSignIn() {
        SignInAlert.cancel()
        cancelledLogin = true
        closeLoginFailed(waiting: 10)
    }

    /// Closes the known "Login failed" alert if it is up, or comes up within
    /// `seconds`. Returns whether it did.
    @discardableResult
    func closeLoginFailed(waiting seconds: TimeInterval = 0) -> Bool {
        let failed = app.alerts["Login failed"]
        guard failed.exists || (seconds > 0 && failed.waitForExistence(timeout: seconds)) else { return false }
        XCTContext.runActivity(named: "Known issue (LOGIN-B01): \"Login failed\" after a cancelled login, closed") { _ in }
        failed.buttons["OK"].tap()
        return true
    }

    /// Creates a profile logged in with the setup key from NB_SETUP_KEY — the
    /// stand-in for the plan's "authenticated profile", made through the UI
    /// rather than seeded, since the app is not modified for testing.
    func createSignedInProfile() throws -> String {
        let setupKey = try TestSecrets.value("NB_SETUP_KEY")
        let profile = newProfileName()
        step("Create \(profile), signed in with the setup key") {
            profiles.open()
            profiles.create(profile, setupKey: setupKey)
        }
        return profile
    }

    /// Creates a profile on NetBird Cloud without a setup key: it has never
    /// signed in, so connecting it asks for an SSO login.
    func createSignedOutProfile() -> String {
        let profile = newProfileName()
        step("Create \(profile), signed out") {
            profiles.open()
            profiles.create(profile)
        }
        return profile
    }

    /// Watches the toggle for a while: it must settle on Disconnected and
    /// never reach Connected.
    func expectStaysDisconnected(for seconds: TimeInterval,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(seconds)
        var last = ""
        while Date() < deadline {
            last = connection.state
            if last == "Connected" {
                XCTFail("the VPN connected without a login", file: file, line: line)
                return
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertEqual(last, "Disconnected", "the VPN did not settle on Disconnected", file: file, line: line)
    }

    /// Connects and checks it got there with no login asked for and no
    /// login error.
    func connectWithoutLogin(file: StaticString = #filePath, line: UInt = #line) {
        connection.connect()
        XCTAssertEqual(connection.state, "Connected", "not connected", file: file, line: line)
        XCTAssertFalse(SignInAlert.isShowing, "a login was asked for", file: file, line: line)
        XCTAssertFalse(app.alerts["Login failed"].exists, "a login error is shown", file: file, line: line)
    }

    /// Skips a test that needs to connect: VPN configurations cannot be saved
    /// in the Simulator, so Connect does nothing there.
    func requireDevice() throws {
        if isSimulator {
            throw XCTSkip("connecting needs a physical device")
        }
    }

    var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    /// Undoes what an earlier test may have left on for the whole device: an
    /// alert the app raised by itself, and VPN On Demand. On Demand left on
    /// makes iOS reconnect by itself, raises "Authentication required" over
    /// the screens a test needs, and turns every disconnect into a prompt —
    /// one test that could not switch it off failed all the ones after it.
    private func resetDeviceWideState() {
        let closed = AppAlerts.dismissAll(in: app)
        let onDemand = OnDemandScreen(app: app)
        onDemand.open()
        let wasOn = onDemand.isOn
        onDemand.set(false)
        AppAlerts.dismissAll(in: app)
        if !closed.isEmpty || wasOn {
            XCTContext.runActivity(named: "Reset left-over state: "
                + (closed.map { "closed \"\($0)\"" } + (wasOn ? ["switched VPN On Demand off"] : [])).joined(separator: ", ")) { _ in }
        }
        XCTAssertFalse(onDemand.isOn, "VPN On Demand could not be switched off")
    }

    /// Removes test profiles a failed run left behind. An active profile
    /// cannot be removed, so a test profile that is still active is switched
    /// away from first — to "default", which always exists.
    private func removeLeftovers() {
        profiles.open()
        let leftovers = profiles.leftoverTestProfiles
        guard !leftovers.isEmpty else { return }

        step("Remove leftovers: \(leftovers.joined(separator: ", "))") {
            // Switching away closes the VPN by itself. No separate disconnect
            // first: a leftover stuck in Connecting ignores the toggle, and
            // waiting for it to read Disconnected failed every later test.
            if let active = profiles.activeProfileName, active.hasPrefix(ProfilesScreen.testProfilePrefix) {
                profiles.switchTo("default")
            }
            for name in leftovers {
                profiles.remove(name)
            }
        }
    }
}
