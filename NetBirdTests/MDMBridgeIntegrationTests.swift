//
//  MDMBridgeIntegrationTests.swift
//  NetBirdTests
//
//  End-to-end check of the MDM bridge without an MDM server: writes the
//  managed-configuration dictionary the OS would push, then reads the
//  enforcement snapshot back through the Go layer.
//
//  Covers Swift fetcher -> Go policy loader -> BuildRestrictions -> Swift
//  decode. The only link it cannot cover is the OS actually delivering the
//  dictionary, which needs a device enrolled in a real MDM.
//

import XCTest
@testable import NetBird

final class MDMBridgeIntegrationTests: XCTestCase {

    private let key = MDMPolicyFetcher.managedConfigKey
    private var saved: [String: Any]?

    /// True when the scheme passes a policy as a launch argument. The
    /// argument domain outranks every other domain and cannot be cleared at
    /// runtime, so these tests cannot establish a known starting state and
    /// must skip rather than report a false result.
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

    /// The fetcher must hand the Go layer exactly what the OS store holds.
    func testFetcherSerializesManagedConfiguration() {
        push(["disableProfiles": true, "managementURL": "https://mgmt.example:443"])
        let json = MDMPolicyFetcher().fetchJSON()
        XCTAssertTrue(json.contains("disableProfiles"), "fetcher returned: \(json)")
        XCTAssertTrue(json.contains("mgmt.example"), "fetcher returned: \(json)")
    }

    /// No managed configuration means an empty string, which the Go layer
    /// reads as "no policy" - the unmanaged install must behave as before.
    func testNoManagedConfigurationYieldsEmptyPolicy() {
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(MDMPolicyFetcher().fetchJSON(), "")
        XCTAssertEqual(MDMRestrictions.current(), .empty)
    }

    /// The whole round trip: a pushed policy must come back as rendered
    /// enforcement state.
    func testPushedPolicyReachesRestrictions() {
        push([
            "managementURL": "https://mgmt.example:443",
            "preSharedKey": "dGVzdC1rZXktdmFsdWUtZm9yLXVuaXQtdGVzdHMtMDE=",
            "rosenpassEnabled": true,
            "disableClientRoutes": true,
            "disableAutoConnect": true,
            "disableProfiles": true,
            "disableNetworks": true,
            "disableUpdateSettings": true,
        ])

        let r = MDMRestrictions.current()
        XCTAssertTrue(r.mdm.managesManagementURL, "managementURL was: '\(r.mdm.managementURL)'")
        XCTAssertTrue(r.mdm.managementURL.contains("mgmt.example"))
        XCTAssertTrue(r.mdm.preSharedKey)
        XCTAssertTrue(r.mdm.rosenpassEnabled)
        XCTAssertTrue(r.mdm.disableClientRoutes)
        XCTAssertTrue(r.mdm.disableAutoConnect)
        XCTAssertTrue(r.features.disableProfiles)
        XCTAssertTrue(r.features.disableNetworks)
        XCTAssertTrue(r.features.disableUpdateSettings)
    }

    /// Keys absent from the policy must stay unmanaged, so a partial policy
    /// locks only what it names.
    func testPartialPolicyLocksOnlyNamedKeys() {
        push(["disableNetworks": true])
        let r = MDMRestrictions.current()
        XCTAssertTrue(r.features.disableNetworks)
        XCTAssertFalse(r.features.disableProfiles)
        XCTAssertFalse(r.mdm.preSharedKey)
        XCTAssertFalse(r.mdm.managesManagementURL)
    }
}
