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
import CryptoKit
import NetBirdSDK

@objc public final class MDMPolicyFetcher: NSObject, NetBirdSDKPolicyFetcherProtocol {
    /// The well-known iOS UserDefaults key under which an MDM-pushed
    /// Configuration Profile lands the managed-config dictionary.
    public static let managedConfigKey = "com.apple.configuration.managed"

    private let userDefaults: UserDefaults
    private let key: String

    public override convenience init() {
        self.init(userDefaults: .standard, key: Self.managedConfigKey)
    }

    init(userDefaults: UserDefaults, key: String) {
        self.userDefaults = userDefaults
        self.key = key
        super.init()
    }

    static func mirrored() -> MDMPolicyFetcher {
        let defaults = UserDefaults(suiteName: GlobalConstants.userPreferencesSuiteName) ?? .standard
        return MDMPolicyFetcher(userDefaults: defaults, key: MDMPolicyMirror.policyKey)
    }

    public func fetchJSON() -> String {
        guard let dict = userDefaults.dictionary(forKey: key),
              !dict.isEmpty else {
            return ""
        }
        // JSONSerialization rejects non-JSON values (e.g. Date, URL,
        // custom NSObject); MDM payloads on iOS may contain Data or
        // Date that Apple Configurator inserts on signed profiles. The
        // sanitizer below coerces those into JSON-friendly shapes so
        // a single bad value cannot break the whole snapshot.
        let sanitized = Self.sanitizeForJSON(Self.policyDictionary(from: dict))
        guard JSONSerialization.isValidJSONObject(sanitized),
              let data = try? JSONSerialization.data(withJSONObject: sanitized, options: []),
              let json = String(data: data, encoding: .utf8) else {
            AppLogger.shared.log("MDMPolicyFetcher: failed to JSON-encode managed configuration; returning empty")
            return ""
        }
        return json
    }

    private static func policyDictionary(from managedConfiguration: [String: Any]) -> [String: Any] {
        var policy = managedConfiguration
        if policy["managementURL"] == nil, let legacyURL = policy.removeValue(forKey: "managementUrl") {
            policy["managementURL"] = legacyURL
        }
        policy.removeValue(forKey: MDMPolicyMirror.setupKey)
        policy.removeValue(forKey: "adminURL")
        policy.removeValue(forKey: "adminUrl")
        return policy
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

enum MDMPolicyMirror {
    static let policyKey = "netbird.mdm.policy"
    static let changeNotification = "io.netbird.mdm.policyChanged" as CFString
    static let setupKey = "setupKey"

    @discardableResult
    static func synchronize(
        source: UserDefaults = .standard,
        destination: UserDefaults? = UserDefaults(suiteName: GlobalConstants.userPreferencesSuiteName)
    ) -> Bool {
        guard let destination else {
            AppLogger.shared.log("MDMPolicyMirror: App Group defaults are unavailable")
            return false
        }

        let fetcher = MDMPolicyFetcher(
            userDefaults: source,
            key: MDMPolicyFetcher.managedConfigKey
        )
        let json = fetcher.fetchJSON()
        let data = json.data(using: .utf8)
        let policy = data.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        } ?? [:]

        let previous = destination.dictionary(forKey: policyKey) ?? [:]
        guard !NSDictionary(dictionary: previous).isEqual(to: policy) else {
            return false
        }

        if policy.isEmpty {
            destination.removeObject(forKey: policyKey)
        } else {
            destination.set(policy, forKey: policyKey)
        }
        destination.synchronize()
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(changeNotification),
            nil,
            nil,
            true
        )
        return true
    }
}

final class MDMPolicyChangeObserver {
    private let handler: () -> Void
    private let lock = NSLock()
    private var isObserving = false

    init(handler: @escaping () -> Void) {
        self.handler = handler
    }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !isObserving else { return }
        isObserving = true
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                Unmanaged<MDMPolicyChangeObserver>
                    .fromOpaque(observer)
                    .takeUnretainedValue()
                    .handler()
            },
            MDMPolicyMirror.changeNotification,
            nil,
            .deliverImmediately
        )
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard isObserving else { return }
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(MDMPolicyMirror.changeNotification),
            nil
        )
        isObserving = false
    }

    deinit {
        stop()
    }
}

struct MDMEnrollmentConfiguration: Equatable {
    let managementURL: String
    let adminURL: String?
    let setupKey: String

    static func current(userDefaults: UserDefaults = .standard) -> MDMEnrollmentConfiguration? {
        guard let managed = userDefaults.dictionary(forKey: MDMPolicyFetcher.managedConfigKey),
              let managementURL = string(in: managed, keys: ["managementURL", "managementUrl"]),
              let setupKey = string(in: managed, keys: [MDMPolicyMirror.setupKey]) else {
            return nil
        }
        return MDMEnrollmentConfiguration(
            managementURL: managementURL,
            adminURL: string(in: managed, keys: ["adminURL", "adminUrl"]),
            setupKey: setupKey
        )
    }

    private static func string(in values: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = values[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }
}

private final class MDMEnrollmentListener: NSObject, NetBirdSDKErrListenerProtocol {
    private let completion: (Error?) -> Void

    init(completion: @escaping (Error?) -> Void) {
        self.completion = completion
    }

    func onSuccess() {
        completion(nil)
    }

    func onError(_ error: Error?) {
        completion(error)
    }
}

actor MDMZeroTouchEnrollment {
    static let shared = MDMZeroTouchEnrollment()

    private static let completedEnrollmentsKey = "netbird.mdm.completedEnrollments"

    private init() {}

    func enrollIfNeeded(userDefaults: UserDefaults = .standard) async {
        guard let configuration = MDMEnrollmentConfiguration.current(userDefaults: userDefaults),
              let configPath = Preferences.configFile(),
              let statePath = Preferences.stateFile() else {
            return
        }

        let profileID = Self.digest(configPath)
        let fingerprint = Self.digest(
            [configuration.managementURL, configuration.adminURL ?? "", configuration.setupKey]
                .joined(separator: "\u{0}")
        )
        var completed = userDefaults.dictionary(forKey: Self.completedEnrollmentsKey) as? [String: String] ?? [:]
        let configExists = FileManager.default.fileExists(atPath: configPath)
        if configExists, completed[profileID] == fingerprint {
            return
        }

        if configExists, !await Self.loginIsRequired(configPath: configPath, statePath: statePath) {
            guard persistAdminURL(configuration.adminURL, configPath: configPath, statePath: statePath) else {
                return
            }
            completed[profileID] = fingerprint
            userDefaults.set(completed, forKey: Self.completedEnrollmentsKey)
            return
        }

        var authError: NSError?
        guard let auth = NetBirdSDKNewAuth(
            configPath,
            configuration.managementURL,
            MDMPolicyFetcher(),
            &authError
        ) else {
            AppLogger.shared.log(
                "MDM enrollment: could not initialize authentication - "
                + (authError?.localizedDescription ?? "unknown error")
            )
            return
        }

        let loginError = await withCheckedContinuation { continuation in
            let listener = MDMEnrollmentListener { error in
                continuation.resume(returning: error)
            }
            auth.login(
                withSetupKeyAndSaveConfig: listener,
                setupKey: configuration.setupKey,
                deviceName: Device.getName()
            )
        }
        if let loginError {
            AppLogger.shared.log("MDM enrollment: setup-key login failed - \(loginError.localizedDescription)")
            return
        }

        guard persistAdminURL(configuration.adminURL, configPath: configPath, statePath: statePath) else {
            return
        }

        ProfileManager.shared.saveServerURL(configuration.managementURL, forID: ProfileManager.shared.getActiveProfileID())
        Preferences.saveManagementURL(configuration.managementURL)
        completed[profileID] = fingerprint
        userDefaults.set(completed, forKey: Self.completedEnrollmentsKey)
        AppLogger.shared.log("MDM enrollment: setup-key login completed")
    }

    private func persistAdminURL(_ adminURL: String?, configPath: String, statePath: String) -> Bool {
        guard let adminURL else { return true }
        guard let preferences = NetBirdSDKNewPreferences(configPath, statePath) else {
            AppLogger.shared.log("MDM enrollment: could not initialize preferences for the admin URL")
            return false
        }
        preferences.setAdminURL(adminURL)
        do {
            try preferences.commit()
            return true
        } catch {
            AppLogger.shared.log("MDM enrollment: could not persist the admin URL - \(error.localizedDescription)")
            return false
        }
    }

    private static func loginIsRequired(configPath: String, statePath: String) async -> Bool {
        let cachePath = Preferences.cacheDirectory()
        let deviceName = Device.getName()
        let osVersion = Device.getOsVersion()
        let osName = Device.getOsName()
        return await Task.detached(priority: .utility) {
            guard let client = NetBirdSDKNewClient(
                configPath,
                statePath,
                cachePath,
                "",
                deviceName,
                osVersion,
                osName,
                nil,
                nil
            ) else {
                return true
            }
            client.setMDMPolicyFetcher(MDMPolicyFetcher())
            return client.isLoginRequired()
        }.value
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
