//
//  MDMPolicyFetcher.swift
//  NetbirdKit
//
//  Reads the current iOS managed-configuration snapshot
//  (UserDefaults key "com.apple.configuration.managed", pushed by MDM
//  controllers via an Apple Configuration Profile of type
//  com.apple.app.configuration.managed) and exposes it to the Go layer
//  as a JSON-encoded string.
//
//  Registered exactly once per process via
//  NetBirdSDKSetMobilePolicyFetcher; the Go side invokes fetchJSON()
//  on every LoadPolicy call so the response is always fresh — no
//  Swift-side caching.
//
//  Return-value contract (matches the Go-side jsonFetcherAdapter):
//    - "" (empty)   : no MDM source present / no managed keys
//    - "{}"         : managed config explicitly empty
//    - "{...}"      : JSON object with key/value pairs
//    - malformed    : logged, treated as empty
//

import Foundation
import NetBirdSDK

@objc public final class MDMPolicyFetcher: NSObject, NetBirdSDKPolicyFetcherProtocol {
    /// The well-known iOS UserDefaults key under which an MDM-pushed
    /// Configuration Profile lands the managed-config dictionary.
    public static let managedConfigKey = "com.apple.configuration.managed"

    public func fetchJSON() -> String {
        guard let dict = UserDefaults.standard.dictionary(forKey: Self.managedConfigKey),
              !dict.isEmpty else {
            return ""
        }
        // JSONSerialization rejects non-JSON values (e.g. Date, URL,
        // custom NSObject); MDM payloads on iOS may contain Data or
        // Date that Apple Configurator inserts on signed profiles. The
        // sanitizer below coerces those into JSON-friendly shapes so
        // a single bad value cannot break the whole snapshot.
        let sanitized = Self.sanitizeForJSON(dict)
        guard JSONSerialization.isValidJSONObject(sanitized),
              let data = try? JSONSerialization.data(withJSONObject: sanitized, options: []),
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
