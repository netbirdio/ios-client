//
//  MDMPolicyFetcher.swift
//  NetbirdKit
//
//  Hands the Go layer the current MDM managed configuration as a JSON
//  string. The Go side calls fetchJSON() on every policy load, so the
//  answer is always read fresh - there is no Swift-side cache.
//
//  Where the configuration comes from depends on the process:
//
//    - The app. iOS delivers managed app configuration (the
//      "com.apple.configuration.managed" dictionary) to the managed app's
//      own preferences domain, so the app reads UserDefaults.standard and
//      nothing else.
//
//    - The network extension. It is a separate bundle with a separate
//      preferences domain, and the OS never delivers the dictionary there:
//      UserDefaults.standard in the extension is empty. The app therefore
//      mirrors the dictionary into the shared App Group, and the extension
//      reads that copy. Its own domain is still consulted first, so if iOS
//      ever does deliver there, the fresher value wins.
//
//  The mirror is only as current as the app's last run: a policy that
//  lands while the tunnel is brought up by On Demand or the widget,
//  without the app opening, is read as the previous copy until the app
//  next activates.
//
//  Return-value contract (matches the Go-side JSON loader):
//    - "" (empty)   : no managed configuration
//    - "{...}"      : JSON object with key/value pairs
//    - malformed    : logged, treated as empty
//

import Foundation
import NetBirdSDK

@objc public final class MDMPolicyFetcher: NSObject, NetBirdSDKPolicyFetcherProtocol {
    /// The well-known key under which iOS stores the managed-config
    /// dictionary in the managed app's preferences.
    public static let managedConfigKey = "com.apple.configuration.managed"

    public func fetchJSON() -> String {
        Self.fetchJSON(inExtension: Self.isRunningInExtension)
    }

    /// Source selection, split out so both paths are testable from the app
    /// process that hosts the tests.
    static func fetchJSON(inExtension: Bool) -> String {
        let own = encodedManagedConfiguration(in: .standard)
        #if os(iOS)
        // The app is authoritative and never reads the mirror: after a policy
        // is removed its own domain is empty, and falling back to the copy
        // would resurrect the policy it just lost.
        guard inExtension, own.isEmpty else { return own }
        return Preferences.sharedUserDefaults()?
            .string(forKey: GlobalConstants.keyMDMManagedConfigMirror) ?? ""
        #else
        // tvOS: App Group suites do not work between the app and the extension
        // there (see Preferences.sharedUserDefaults), so there is no mirror to
        // read. Configuration reaches the tvOS extension over IPC instead.
        return own
        #endif
    }

    /// True inside an app extension bundle, where the managed configuration
    /// is not delivered.
    static var isRunningInExtension: Bool {
        Bundle.main.bundleURL.pathExtension == "appex"
    }

    /// Copies the app's managed configuration into the App Group for the
    /// network extension, and tells a running extension when it changed.
    ///
    /// Call it whenever the app may have received a new policy - on
    /// activation, when the restrictions snapshot is refreshed, and right
    /// before starting the tunnel. It is a no-op outside the app process:
    /// every other process sees an empty domain and would wipe the copy.
    ///
    /// - Returns: whether the mirror changed. An unchanged policy is not
    ///   rewritten and does not wake the extension.
    @discardableResult
    static func mirrorToAppGroup() -> Bool {
        #if os(iOS)
        guard !isRunningInExtension,
              let shared = Preferences.sharedUserDefaults() else {
            return false
        }
        let current = encodedManagedConfiguration(in: .standard)
        let previous = shared.string(forKey: GlobalConstants.keyMDMManagedConfigMirror) ?? ""
        guard current != previous else { return false }

        if current.isEmpty {
            shared.removeObject(forKey: GlobalConstants.keyMDMManagedConfigMirror)
        } else {
            shared.set(current, forKey: GlobalConstants.keyMDMManagedConfigMirror)
        }
        shared.synchronize()
        AppLogger.shared.log("MDMPolicyFetcher: App Group mirror \(current.isEmpty ? "cleared" : "updated (\(current.count) bytes)")")

        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(GlobalConstants.darwinNotificationMDMPolicyChanged as CFString),
            nil,
            nil,
            true
        )
        return true
        #else
        return false
        #endif
    }

    /// Encodes the managed-config dictionary in `defaults` as JSON, or ""
    /// when there is none.
    ///
    /// Keys are sorted so the same policy always encodes to the same string;
    /// otherwise the mirror would compare unequal on dictionary ordering alone
    /// and wake the extension for nothing.
    private static func encodedManagedConfiguration(in defaults: UserDefaults) -> String {
        guard let dict = defaults.dictionary(forKey: managedConfigKey),
              !dict.isEmpty else {
            return ""
        }
        // JSONSerialization rejects non-JSON values such as Date, URL or
        // Data, which MDM payloads can carry. The sanitizer coerces those so a
        // single odd value cannot break the whole snapshot.
        let sanitized = sanitizeForJSON(dict)
        guard JSONSerialization.isValidJSONObject(sanitized),
              let data = try? JSONSerialization.data(withJSONObject: sanitized, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            AppLogger.shared.log("MDMPolicyFetcher: failed to JSON-encode managed configuration; returning empty")
            return ""
        }
        return json
    }

    /// Recursively coerces a Foundation-typed managed-config value into
    /// something JSONSerialization will accept. The Go side ultimately
    /// expects map[string]any with bool / string / number / array /
    /// nested-map values — anything else is dropped or stringified.
    private static func sanitizeForJSON(_ value: Any) -> Any {
        switch value {
        case let dict as [String: Any]:
            var out: [String: Any] = [:]
            for (k, v) in dict {
                out[k] = sanitizeForJSON(v)
            }
            return out
        case let arr as [Any]:
            return arr.map { sanitizeForJSON($0) }
        case let data as Data:
            return data.base64EncodedString()
        case let date as Date:
            return ISO8601DateFormatter().string(from: date)
        case let url as URL:
            return url.absoluteString
        case is NSNumber, is String, is Bool, is Int, is Double, is Float:
            return value
        case is NSNull:
            return NSNull()
        default:
            // Last resort: stringify so the Go side at least sees the
            // key as managed (not silently swallowed).
            return "\(value)"
        }
    }
}
