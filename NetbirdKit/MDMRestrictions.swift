//
//  MDMRestrictions.swift
//  NetbirdKit
//
//  Swift mirror of the Go-side UI enforcement snapshot returned by
//  getRestrictionsJSON() — the same JSON shape the desktop frontend
//  consumes. Every MDM decision is made in Go; this type only carries
//  the rendered answer so views can hide or lock a control.
//
//  Semantics:
//    - mdm.managementURL  : the enforced value ("" = not managed)
//    - other mdm.* flags  : true = the key is managed, lock the control
//    - mdm.allowServerSSH : tri-state, nil = not managed
//    - features.*         : the enforced value of that gate
//

import Foundation
import NetBirdSDK

struct MDMRestrictions: Equatable {

    struct Fields: Equatable {
        var managementURL: String = ""
        var preSharedKey: Bool = false
        var wireguardPort: Bool = false
        var rosenpassEnabled: Bool = false
        var rosenpassPermissive: Bool = false
        var disableClientRoutes: Bool = false
        var disableServerRoutes: Bool = false
        var allowServerSSH: Bool?
        var disableAutoConnect: Bool = false
        var disableAutostart: Bool = false
        var blockInbound: Bool = false
        var disableMetricsCollection: Bool = false
        var splitTunnelMode: Bool = false
        var splitTunnelApps: Bool = false
        var disableAdvancedView: Bool = false

        /// True when a management URL is enforced by policy.
        var managesManagementURL: Bool { !managementURL.isEmpty }
    }

    struct Features: Equatable {
        var disableProfiles: Bool = false
        var disableNetworks: Bool = false
        var disableUpdateSettings: Bool = false
    }

    var mdm = Fields()
    var features = Features()

    /// The no-policy snapshot: nothing managed, nothing gated. Also the
    /// fallback whenever the bridge cannot be read, so a failure leaves
    /// the app fully usable instead of locking the user out.
    static let empty = MDMRestrictions()
}

// MARK: - Decoding

// The initializers below use decodeIfPresent throughout rather than the
// synthesized Decodable conformance: the synthesized one requires every
// key to be present and would reject a snapshot from a Go layer that has
// added or dropped a key. Missing keys fall back to "not managed".
extension MDMRestrictions: Decodable {
    enum CodingKeys: String, CodingKey {
        case mdm, features
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mdm = try c.decodeIfPresent(Fields.self, forKey: .mdm) ?? Fields()
        features = try c.decodeIfPresent(Features.self, forKey: .features) ?? Features()
    }
}

extension MDMRestrictions.Fields: Decodable {
    enum CodingKeys: String, CodingKey {
        case managementURL, preSharedKey, wireguardPort, rosenpassEnabled,
             rosenpassPermissive, disableClientRoutes, disableServerRoutes,
             allowServerSSH, disableAutoConnect, disableAutostart, blockInbound,
             disableMetricsCollection, splitTunnelMode, splitTunnelApps,
             disableAdvancedView
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func flag(_ key: CodingKeys) throws -> Bool {
            try c.decodeIfPresent(Bool.self, forKey: key) ?? false
        }
        managementURL = try c.decodeIfPresent(String.self, forKey: .managementURL) ?? ""
        preSharedKey = try flag(.preSharedKey)
        wireguardPort = try flag(.wireguardPort)
        rosenpassEnabled = try flag(.rosenpassEnabled)
        rosenpassPermissive = try flag(.rosenpassPermissive)
        disableClientRoutes = try flag(.disableClientRoutes)
        disableServerRoutes = try flag(.disableServerRoutes)
        // Tri-state: absent and JSON null both mean "not managed".
        allowServerSSH = try c.decodeIfPresent(Bool.self, forKey: .allowServerSSH)
        disableAutoConnect = try flag(.disableAutoConnect)
        disableAutostart = try flag(.disableAutostart)
        blockInbound = try flag(.blockInbound)
        disableMetricsCollection = try flag(.disableMetricsCollection)
        splitTunnelMode = try flag(.splitTunnelMode)
        splitTunnelApps = try flag(.splitTunnelApps)
        disableAdvancedView = try flag(.disableAdvancedView)
    }
}

extension MDMRestrictions.Features: Decodable {
    enum CodingKeys: String, CodingKey {
        case disableProfiles, disableNetworks, disableUpdateSettings
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        disableProfiles = try c.decodeIfPresent(Bool.self, forKey: .disableProfiles) ?? false
        disableNetworks = try c.decodeIfPresent(Bool.self, forKey: .disableNetworks) ?? false
        disableUpdateSettings = try c.decodeIfPresent(Bool.self, forKey: .disableUpdateSettings) ?? false
    }
}

// MARK: - Reading the snapshot

extension MDMRestrictions {

    /// Parses a snapshot produced by getRestrictionsJSON(). Never throws:
    /// an unreadable snapshot degrades to `.empty` so a malformed policy
    /// cannot brick the settings screens.
    static func decode(_ json: String) -> MDMRestrictions {
        guard !json.isEmpty, let data = json.data(using: .utf8) else {
            return .empty
        }
        do {
            return try JSONDecoder().decode(MDMRestrictions.self, from: data)
        } catch {
            AppLogger.shared.log("MDMRestrictions: failed to decode snapshot - \(error)")
            return .empty
        }
    }

    /// Reads the current snapshot through the Go bridge.
    ///
    /// A dedicated Preferences instance is used rather than the app's
    /// shared one because getRestrictionsJSON() consults only the policy
    /// loader — it never reads or writes the config file — so this is
    /// side-effect free and works on tvOS too, where the app process has
    /// no file-backed Preferences of its own.
    static func current() -> MDMRestrictions {
        guard let configPath = Preferences.configFile(),
              let statePath = Preferences.stateFile(),
              let preferences = NetBirdSDKNewPreferences(configPath, statePath) else {
            return .empty
        }
        preferences.setMDMPolicyFetcher(MDMPolicyFetcher())
        // gomobile maps (string, error) with a non-null string to an
        // NSErrorPointer out-parameter, not to a throwing call.
        var error: NSError?
        let json = preferences.getRestrictionsJSON(&error)
        if let error = error {
            AppLogger.shared.log("MDMRestrictions: failed to read snapshot - \(error)")
            return .empty
        }
        return decode(json)
    }
}
