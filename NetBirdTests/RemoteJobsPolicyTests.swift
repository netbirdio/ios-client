//
//  RemoteJobsPolicyTests.swift
//  NetBirdTests
//
//  Covers the backstop on the remote debug bundle toggle: a policy pushed
//  from another process must be enforced by the very next write, not from
//  the next poll onwards. Runs on iOS and tvOS - on tvOS commit() always
//  reports success, so the pre-commit guard is the only thing standing
//  between a managed device and an enabled remote job.
//

import XCTest
@testable import NetBird

final class RemoteJobsPolicyTests: XCTestCase {

    private let key = MDMPolicyFetcher.managedConfigKey
    private var saved: [String: Any]?

    private var policyForcedByLaunchArgument: Bool {
        UserDefaults.standard
            .volatileDomain(forName: UserDefaults.argumentDomain)[key] != nil
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipIf(
            policyForcedByLaunchArgument,
            "A policy is pinned by the scheme's launch arguments "
            + "(-\(MDMPolicyFetcher.managedConfigKey)). Uncheck it in "
            + "Edit Scheme > Run > Arguments to run these tests."
        )
        saved = UserDefaults.standard.dictionary(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
    }

    override func tearDown() {
        if let saved = saved {
            UserDefaults.standard.set(saved, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        super.tearDown()
    }

    private func push(_ policy: [String: Any]) {
        UserDefaults.standard.set(policy, forKey: key)
        UserDefaults.standard.synchronize()
    }

    /// A ViewModel holding the unmanaged snapshot the app starts with, which
    /// is what a policy arriving mid-session has to override.
    @MainActor
    private func makeViewModelWithStaleSnapshot() -> ViewModel {
        let viewModel = ViewModel()
        viewModel.mdmRestrictions = .empty
        XCTAssertFalse(viewModel.mdmRestrictions.mdm.remoteJobsAllowed)
        XCTAssertFalse(viewModel.mdmRestrictions.features.disableUpdateSettings)
        return viewModel
    }

    @MainActor
    func testAllowRemoteJobsPolicyIsEnforcedBeforeTheNextPoll() throws {
        let viewModel = makeViewModelWithStaleSnapshot()
        push(["allowRemoteJobs": false])
        try XCTSkipUnless(
            MDMRestrictions.current().mdm.remoteJobsAllowed,
            "the Go policy loader did not render allowRemoteJobs as managed"
        )

        viewModel.setRemoteJobsAllowed(allowed: true)

        XCTAssertTrue(viewModel.showSettingsRejectedAlert)
        XCTAssertEqual(
            viewModel.settingsRejectedMessage,
            "This setting is managed by your organization and cannot be changed."
        )
        XCTAssertTrue(viewModel.mdmRestrictions.mdm.remoteJobsAllowed)
    }

    /// disableUpdateSettings locks the toggle in both UIs, so the setter has
    /// to refuse on it too - otherwise the lock is cosmetic.
    @MainActor
    func testDisableUpdateSettingsPolicyIsEnforcedBeforeTheNextPoll() throws {
        let viewModel = makeViewModelWithStaleSnapshot()
        push(["disableUpdateSettings": true])
        try XCTSkipUnless(
            MDMRestrictions.current().features.disableUpdateSettings,
            "the Go policy loader did not render disableUpdateSettings as managed"
        )

        viewModel.setRemoteJobsAllowed(allowed: true)

        XCTAssertTrue(viewModel.showSettingsRejectedAlert)
        XCTAssertEqual(
            viewModel.settingsRejectedMessage,
            "This setting is managed by your organization and cannot be changed."
        )
        XCTAssertTrue(viewModel.mdmRestrictions.features.disableUpdateSettings)
    }

    /// The refresh must not turn an unmanaged device read-only.
    @MainActor
    func testUnmanagedDeviceStillAcceptsTheChange() throws {
        let viewModel = makeViewModelWithStaleSnapshot()
        try XCTSkipUnless(
            MDMRestrictions.current() == .empty,
            "the environment reports a policy for an unmanaged device"
        )

        viewModel.loadRemoteJobsSettings()
        let original = viewModel.remoteJobsAllowed
        defer { viewModel.setRemoteJobsAllowed(allowed: original) }

        viewModel.setRemoteJobsAllowed(allowed: true)

        XCTAssertFalse(viewModel.showSettingsRejectedAlert)
        XCTAssertTrue(viewModel.remoteJobsAllowed)
    }
}
