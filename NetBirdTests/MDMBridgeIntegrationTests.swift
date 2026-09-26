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
    private var savedMirror: String?

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
        savedMirror = Preferences.sharedUserDefaults()?
            .string(forKey: GlobalConstants.keyMDMManagedConfigMirror)
        Preferences.sharedUserDefaults()?
            .removeObject(forKey: GlobalConstants.keyMDMManagedConfigMirror)
    }

    override func tearDown() {
        if let savedMirror = savedMirror {
            Preferences.sharedUserDefaults()?
                .set(savedMirror, forKey: GlobalConstants.keyMDMManagedConfigMirror)
        } else {
            Preferences.sharedUserDefaults()?
                .removeObject(forKey: GlobalConstants.keyMDMManagedConfigMirror)
        }
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

    // MARK: - Delivery to the network extension
    //
    // iOS puts managed configuration in the app's preferences domain only; the
    // extension's own domain is empty. These cover the App Group mirror that
    // carries it across, reading as the extension would.

    /// The whole point of the mirror: a policy only the app can see must be
    /// readable from the extension's path.
    func testMirrorCarriesPolicyToTheExtension() {
        push(["disableNetworks": true])
        XCTAssertTrue(MDMPolicyFetcher.mirrorToAppGroup())

        // What the extension sees of its own domain: nothing.
        UserDefaults.standard.removeObject(forKey: key)
        let json = MDMPolicyFetcher.fetchJSON(inExtension: true)
        XCTAssertTrue(json.contains("disableNetworks"), "extension read: \(json)")
    }

    /// A policy removed from the app must stop applying in the extension, not
    /// linger in the copy.
    func testRemovingThePolicyClearsTheMirror() {
        push(["disableNetworks": true])
        MDMPolicyFetcher.mirrorToAppGroup()

        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertTrue(MDMPolicyFetcher.mirrorToAppGroup(), "clearing the copy is a change")
        XCTAssertEqual(MDMPolicyFetcher.fetchJSON(inExtension: true), "")
    }

    /// An unchanged policy must not be rewritten or wake the extension - the
    /// mirror runs on every foreground tick.
    func testUnchangedPolicyDoesNotRewriteTheMirror() {
        push(["disableNetworks": true, "disableProfiles": true])
        XCTAssertTrue(MDMPolicyFetcher.mirrorToAppGroup())
        XCTAssertFalse(MDMPolicyFetcher.mirrorToAppGroup())
    }

    /// If iOS ever does deliver the policy to the extension's own domain, that
    /// fresher value must win over the copy.
    func testExtensionPrefersItsOwnDomainWhenPresent() {
        push(["disableNetworks": true])
        MDMPolicyFetcher.mirrorToAppGroup()

        push(["disableProfiles": true])
        let json = MDMPolicyFetcher.fetchJSON(inExtension: true)
        XCTAssertTrue(json.contains("disableProfiles"), "extension read: \(json)")
        XCTAssertFalse(json.contains("disableNetworks"), "extension read: \(json)")
    }

    /// The app is authoritative: after its policy is removed it must not fall
    /// back to a copy it has not refreshed yet.
    func testAppProcessNeverReadsTheMirror() {
        push(["disableNetworks": true])
        MDMPolicyFetcher.mirrorToAppGroup()

        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(MDMPolicyFetcher.fetchJSON(inExtension: false), "")
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
