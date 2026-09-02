//
//  MDMRestrictionsTests.swift
//  NetBirdTests
//
//  Covers the decode side of the MDM enforcement snapshot: the Swift mirror
//  must survive a Go layer that adds, drops or nulls a key, and must always
//  degrade to "nothing managed" rather than locking the user out.
//

import XCTest
@testable import NetBird

final class MDMRestrictionsTests: XCTestCase {

    /// The full snapshot shape, as documented for getRestrictionsJSON().
    private let fullSnapshot = """
    {
      "mdm": {
        "managementURL": "https://mgmt.corp.example:443",
        "preSharedKey": true,
        "wireguardPort": false,
        "rosenpassEnabled": true,
        "rosenpassPermissive": false,
        "disableClientRoutes": false,
        "disableServerRoutes": false,
        "allowServerSSH": null,
        "disableAutoConnect": true,
        "disableAutostart": false,
        "blockInbound": false,
        "disableMetricsCollection": false,
        "splitTunnelMode": false,
        "splitTunnelApps": false,
        "disableAdvancedView": false
      },
      "features": {
        "disableProfiles": true,
        "disableNetworks": false,
        "disableUpdateSettings": false
      }
    }
    """

    func testDecodesFullSnapshot() {
        let r = MDMRestrictions.decode(fullSnapshot)
        XCTAssertEqual(r.mdm.managementURL, "https://mgmt.corp.example:443")
        XCTAssertTrue(r.mdm.managesManagementURL)
        XCTAssertTrue(r.mdm.preSharedKey)
        XCTAssertTrue(r.mdm.rosenpassEnabled)
        XCTAssertFalse(r.mdm.rosenpassPermissive)
        XCTAssertTrue(r.mdm.disableAutoConnect)
        XCTAssertFalse(r.mdm.disableAdvancedView)
        XCTAssertTrue(r.features.disableProfiles)
        XCTAssertFalse(r.features.disableNetworks)
        XCTAssertFalse(r.features.disableUpdateSettings)
    }

    /// `allowServerSSH` is tri-state: absent and explicit null both mean
    /// "not managed", and must not collapse into `false`.
    func testAllowServerSSHTriState() {
        XCTAssertNil(MDMRestrictions.decode(fullSnapshot).mdm.allowServerSSH)
        XCTAssertNil(MDMRestrictions.decode(#"{"mdm":{}}"#).mdm.allowServerSSH)
        XCTAssertEqual(MDMRestrictions.decode(#"{"mdm":{"allowServerSSH":true}}"#).mdm.allowServerSSH, true)
        XCTAssertEqual(MDMRestrictions.decode(#"{"mdm":{"allowServerSSH":false}}"#).mdm.allowServerSSH, false)
    }

    /// An empty policy must leave every control usable.
    func testEmptyPolicyManagesNothing() {
        let r = MDMRestrictions.decode(#"{"mdm":{"managementURL":""},"features":{}}"#)
        XCTAssertEqual(r, .empty)
        XCTAssertFalse(r.mdm.managesManagementURL)
    }

    func testEmptyStringDecodesToEmpty() {
        XCTAssertEqual(MDMRestrictions.decode(""), .empty)
    }

    /// A malformed snapshot must not lock the settings screens; it degrades
    /// to "nothing managed".
    func testMalformedSnapshotDegradesToEmpty() {
        XCTAssertEqual(MDMRestrictions.decode("not json"), .empty)
        XCTAssertEqual(MDMRestrictions.decode("{"), .empty)
    }

    /// Keys the Swift side does not know about must be ignored rather than
    /// failing the whole decode - the Go layer may ship new ones first.
    func testUnknownKeysAreIgnored() {
        let json = #"{"mdm":{"preSharedKey":true,"someFutureKey":"x"},"features":{"disableNetworks":true,"anotherOne":1}}"#
        let r = MDMRestrictions.decode(json)
        XCTAssertTrue(r.mdm.preSharedKey)
        XCTAssertTrue(r.features.disableNetworks)
    }

    /// Missing keys fall back to "not managed", so a Go layer that drops a
    /// key does not start reporting it as locked.
    func testMissingKeysDefaultToUnmanaged() {
        let r = MDMRestrictions.decode(#"{"mdm":{"preSharedKey":true}}"#)
        XCTAssertTrue(r.mdm.preSharedKey)
        XCTAssertFalse(r.mdm.rosenpassEnabled)
        XCTAssertFalse(r.mdm.disableClientRoutes)
        XCTAssertEqual(r.mdm.managementURL, "")
        XCTAssertFalse(r.features.disableProfiles)
    }

    /// Only a non-empty managementURL means the URL is enforced.
    func testManagesManagementURLRequiresNonEmptyValue() {
        XCTAssertFalse(MDMRestrictions.decode(#"{"mdm":{"managementURL":""}}"#).mdm.managesManagementURL)
        XCTAssertTrue(MDMRestrictions.decode(#"{"mdm":{"managementURL":"https://x"}}"#).mdm.managesManagementURL)
    }
}
