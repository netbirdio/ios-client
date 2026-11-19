//
//  LoginBrowserObservationTests.swift
//  NetBirdTests
//

import XCTest
import Combine
@testable import NetBird

/// The login page is shown from `ViewModel.networkExtensionAdapter.showBrowser`, so a change
/// there must reach views observing the view model at once, not on the next status poll.
final class LoginBrowserObservationTests: XCTestCase {

    @MainActor
    func testAdapterLoginStateChangeNotifiesViewModelObservers() {
        let viewModel = ViewModel()
        var notifications = 0
        let cancellable = viewModel.objectWillChange.sink { _ in notifications += 1 }
        defer { cancellable.cancel() }

        viewModel.networkExtensionAdapter.loginURL = "https://example.com/authorize"
        viewModel.networkExtensionAdapter.showBrowser = true
        XCTAssertGreaterThanOrEqual(notifications, 2)

        let before = notifications
        viewModel.networkExtensionAdapter.loginErrorMessage = "failed"
        XCTAssertGreaterThan(notifications, before)
    }
}
