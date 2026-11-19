//
//  LoginAttemptTests.swift
//  NetBirdTests
//

import XCTest
@testable import NetBird

/// A login flow that the app stopped (replaced by a new Connect, or cancelled) still
/// reports its result later. That late result must not change the current login.
@MainActor
final class LoginAttemptTests: XCTestCase {

    private let authorizeURL = "https://example.com/authorize"

    private func openBrowser(_ adapter: NetworkExtensionAdapter) {
        adapter.loginURL = authorizeURL
        adapter.showBrowser = true
    }

    func testFailureOfCurrentAttemptClosesBrowserAndReportsError() {
        let adapter = NetworkExtensionAdapter()
        let attempt = adapter.beginLoginAttempt(with: nil)
        openBrowser(adapter)

        adapter.applyLoginFailure("token exchange failed", attempt: attempt, browserPhaseStarted: true)

        XCTAssertFalse(adapter.showBrowser)
        XCTAssertEqual(adapter.loginErrorMessage, "token exchange failed")
    }

    func testOwnershipConflictOfCurrentAttemptShowsAccountMessage() {
        let adapter = NetworkExtensionAdapter()
        let attempt = adapter.beginLoginAttempt(with: nil)
        openBrowser(adapter)

        adapter.applyLoginFailure(
            "peer is already registered by a different User or a Setup Key",
            attempt: attempt,
            browserPhaseStarted: true
        )

        XCTAssertFalse(adapter.showBrowser)
        XCTAssertTrue(adapter.loginErrorMessage?.contains("different NetBird account") ?? false)
    }

    func testFailureBeforeBrowserPhaseLeavesUIAlone() {
        let adapter = NetworkExtensionAdapter()
        let attempt = adapter.beginLoginAttempt(with: nil)

        adapter.applyLoginFailure("failed to get OAuth flow", attempt: attempt, browserPhaseStarted: false)

        XCTAssertFalse(adapter.showBrowser)
        XCTAssertNil(adapter.loginErrorMessage)
    }

    /// The reported bug: an old flow times out after 5 min and closes the browser of
    /// the login the user is doing now.
    func testTimeoutOfReplacedAttemptKeepsNewBrowserOpen() {
        let adapter = NetworkExtensionAdapter()
        let old = adapter.beginLoginAttempt(with: nil)
        let current = adapter.beginLoginAttempt(with: nil)
        XCTAssertNotEqual(old, current)
        openBrowser(adapter)

        adapter.applyLoginFailure(
            "interactive sso login failed: waiting for browser login failed: context deadline exceeded",
            attempt: old,
            browserPhaseStarted: true
        )

        XCTAssertTrue(adapter.showBrowser)
        XCTAssertEqual(adapter.loginURL, authorizeURL)
        XCTAssertNil(adapter.loginErrorMessage)
        XCTAssertEqual(adapter.loginAttemptToken, current)
    }

    /// A stopped flow reports "context canceled" right after the new attempt has
    /// started. The new attempt must still own its result afterwards.
    func testCancelErrorOfReplacedAttemptDoesNotBlockNewAttempt() {
        let adapter = NetworkExtensionAdapter()
        let old = adapter.beginLoginAttempt(with: nil)
        let current = adapter.beginLoginAttempt(with: nil)

        adapter.applyLoginFailure("context canceled", attempt: old, browserPhaseStarted: true)
        openBrowser(adapter)
        adapter.applyLoginFailure("token exchange failed", attempt: current, browserPhaseStarted: true)

        XCTAssertFalse(adapter.showBrowser)
        XCTAssertEqual(adapter.loginErrorMessage, "token exchange failed")
    }

    func testSuccessOfReplacedAttemptIsIgnored() {
        let adapter = NetworkExtensionAdapter()
        let old = adapter.beginLoginAttempt(with: nil)
        _ = adapter.beginLoginAttempt(with: nil)
        openBrowser(adapter)

        adapter.applyLoginSuccess(attempt: old)

        XCTAssertFalse(adapter.loginSucceeded)
        XCTAssertTrue(adapter.showBrowser)
    }

    func testCancelErrorAfterUserCancelIsNotShown() {
        let adapter = NetworkExtensionAdapter()
        let attempt = adapter.beginLoginAttempt(with: nil)
        openBrowser(adapter)

        adapter.cancelLogin()
        adapter.applyLoginFailure(
            "interactive sso login failed: waiting for browser login failed: context canceled",
            attempt: attempt,
            browserPhaseStarted: true
        )

        XCTAssertFalse(adapter.showBrowser)
        XCTAssertNil(adapter.loginErrorMessage)
    }

    func testNewAttemptAfterCancelStillWorks() {
        let adapter = NetworkExtensionAdapter()
        _ = adapter.beginLoginAttempt(with: nil)
        adapter.cancelLogin()
        let attempt = adapter.beginLoginAttempt(with: nil)
        openBrowser(adapter)

        adapter.applyLoginFailure("token exchange failed", attempt: attempt, browserPhaseStarted: true)

        XCTAssertEqual(adapter.loginErrorMessage, "token exchange failed")
    }

    func testSuccessOfReplacedAttemptDoesNotPersist() {
        let adapter = NetworkExtensionAdapter()
        let old = adapter.beginLoginAttempt(with: nil)
        _ = adapter.beginLoginAttempt(with: nil)
        var persisted = 0

        adapter.applyLoginSuccess(attempt: old) { persisted += 1 }

        XCTAssertEqual(persisted, 0)
    }

    func testSuccessAfterCancelDoesNotPersist() {
        let adapter = NetworkExtensionAdapter()
        let attempt = adapter.beginLoginAttempt(with: nil)
        adapter.cancelLogin()
        var persisted = 0

        adapter.applyLoginSuccess(attempt: attempt) { persisted += 1 }

        XCTAssertEqual(persisted, 0)
        XCTAssertFalse(adapter.loginSucceeded)
    }

    /// The SDK reports success twice; the result is saved once.
    func testSuccessOfCurrentAttemptPersistsOnce() {
        let adapter = NetworkExtensionAdapter()
        let attempt = adapter.beginLoginAttempt(with: nil)
        openBrowser(adapter)
        var persisted = 0

        adapter.applyLoginSuccess(attempt: attempt) { persisted += 1 }
        adapter.applyLoginSuccess(attempt: attempt) { persisted += 1 }

        XCTAssertEqual(persisted, 1)
        XCTAssertTrue(adapter.loginSucceeded)
        XCTAssertFalse(adapter.showBrowser)
    }

    func testFallbackURLOfCurrentAttemptOpensBrowser() {
        let adapter = NetworkExtensionAdapter()
        let attempt = adapter.beginLoginAttempt(with: nil)

        XCTAssertTrue(adapter.applyFallbackLoginURL(authorizeURL, attempt: attempt))

        XCTAssertTrue(adapter.showBrowser)
        XCTAssertEqual(adapter.loginURL, authorizeURL)
    }

    func testFallbackURLOfReplacedAttemptIsDropped() {
        let adapter = NetworkExtensionAdapter()
        let old = adapter.beginLoginAttempt(with: nil)
        _ = adapter.beginLoginAttempt(with: nil)

        XCTAssertFalse(adapter.applyFallbackLoginURL(authorizeURL, attempt: old))

        XCTAssertFalse(adapter.showBrowser)
        XCTAssertNil(adapter.loginURL)
    }

    func testFallbackURLAfterCancelIsDropped() {
        let adapter = NetworkExtensionAdapter()
        let attempt = adapter.beginLoginAttempt(with: nil)
        adapter.cancelLogin()

        XCTAssertFalse(adapter.applyFallbackLoginURL(authorizeURL, attempt: attempt))

        XCTAssertFalse(adapter.showBrowser)
    }

    func testFallbackIPCSentOnceForCurrentAttempt() {
        let adapter = NetworkExtensionAdapter()
        var sends = 0
        adapter.fallbackLoginIPCOverride = { completion in
            sends += 1
            completion(self.authorizeURL)
        }
        let attempt = adapter.beginLoginAttempt(with: nil)
        var received: String?

        let sent = adapter.sendFallbackLogin(attempt: attempt) { received = $0 }

        XCTAssertTrue(sent)
        XCTAssertEqual(sends, 1)
        XCTAssertEqual(received, authorizeURL)
    }

    func testFallbackIPCNotSentForReplacedAttempt() {
        let adapter = NetworkExtensionAdapter()
        var sends = 0
        adapter.fallbackLoginIPCOverride = { _ in sends += 1 }
        let old = adapter.beginLoginAttempt(with: nil)
        _ = adapter.beginLoginAttempt(with: nil)
        var completed = false

        let sent = adapter.sendFallbackLogin(attempt: old) { _ in completed = true }

        XCTAssertFalse(sent)
        XCTAssertEqual(sends, 0)
        XCTAssertFalse(completed)
    }

    func testFallbackIPCNotSentAfterCancel() {
        let adapter = NetworkExtensionAdapter()
        var sends = 0
        adapter.fallbackLoginIPCOverride = { _ in sends += 1 }
        let attempt = adapter.beginLoginAttempt(with: nil)
        adapter.cancelLogin()

        XCTAssertFalse(adapter.sendFallbackLogin(attempt: attempt) { _ in })
        XCTAssertEqual(sends, 0)
    }

    /// IPC failed for the current attempt: start the VPN to launch the extension.
    func testVPNStartsForCurrentAttemptWithoutBrowser() {
        let adapter = NetworkExtensionAdapter()
        let attempt = adapter.beginLoginAttempt(with: nil)

        XCTAssertTrue(adapter.startVPNAfterLoginIfCurrent(attempt: attempt))
    }

    /// Browser is up: the login is in progress.
    func testVPNDoesNotStartWhileBrowserShown() {
        let adapter = NetworkExtensionAdapter()
        let attempt = adapter.beginLoginAttempt(with: nil)
        openBrowser(adapter)

        XCTAssertFalse(adapter.startVPNAfterLoginIfCurrent(attempt: attempt))
    }

    /// A newer attempt took over after performLogin() returned, its browser not open
    /// yet. The old attempt must leave the connection to it.
    func testVPNDoesNotStartForReplacedAttempt() {
        let adapter = NetworkExtensionAdapter()
        let old = adapter.beginLoginAttempt(with: nil)
        _ = adapter.beginLoginAttempt(with: nil)

        XCTAssertFalse(adapter.startVPNAfterLoginIfCurrent(attempt: old))
    }

    /// An IPC reply with no URL arrives after the user cancelled.
    func testVPNDoesNotStartForCancelledAttempt() {
        let adapter = NetworkExtensionAdapter()
        let attempt = adapter.beginLoginAttempt(with: nil)
        adapter.cancelLogin()

        XCTAssertFalse(adapter.startVPNAfterLoginIfCurrent(attempt: attempt))
    }

    func testRepeatedAttemptsOnlyLatestIsCurrent() {
        let adapter = NetworkExtensionAdapter()
        let attempts = (0..<5).map { _ in adapter.beginLoginAttempt(with: nil) }
        openBrowser(adapter)

        for stale in attempts.dropLast() {
            adapter.applyLoginFailure("context canceled", attempt: stale, browserPhaseStarted: true)
            adapter.applyLoginSuccess(attempt: stale)
        }

        XCTAssertTrue(adapter.showBrowser)
        XCTAssertNil(adapter.loginErrorMessage)
        XCTAssertFalse(adapter.loginSucceeded)
        XCTAssertEqual(adapter.loginAttemptToken, attempts.last)
    }
}
