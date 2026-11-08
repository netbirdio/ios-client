//
//  EnvVarPackager.swift
//  NetBird
//
//  Created by Diego Romar on 03/12/25.
//

import Foundation
import NetBirdSDK

class EnvVarPackager {
    static func getEnvironmentVariables(defaults: UserDefaults) -> NetBirdSDKEnvList? {
        guard let envList = NetBirdSDKEnvList() else {
            return nil
        }

        #if os(iOS)
        let defaultForceRelay = true
        #else
        // Forced relay battery optimization not needed on Apple TV
        let defaultForceRelay = false
        #endif

        defaults.register(defaults: [GlobalConstants.keyForceRelayConnection: defaultForceRelay])
        let forceRelayConnection = defaults.bool(forKey: GlobalConstants.keyForceRelayConnection)

        envList.put(NetBirdSDKGetEnvKeyNBForceRelay(), value: String(forceRelayConnection))

        // LOCAL TEST (battery): relay transport from <group>/Library/Caches/test-relay-transport.
        // Always put a value: os.Setenv persists in the extension process across restarts.
        var relayTransport = "auto"
        if let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: GlobalConstants.userPreferencesSuiteName)?
            .appendingPathComponent("Library/Caches/test-relay-transport"),
           let value = try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            relayTransport = value
        }
        envList.put("NB_RELAY_TRANSPORT", value: relayTransport)
        AppLogger.shared.log("LOCAL TEST: NB_RELAY_TRANSPORT=\(relayTransport)")

        // LOCAL TEST (battery): keepalive overrides from <group>/Library/Caches/test-quiet,
        // lines KEY=SECONDS. Missing keys get "" (core default); always put every key.
        // With SCHEDULE=N the overrides apply only in "on" wall-clock slots of N seconds:
        // slot k = floor((now - SCHEDULE_OFFSET) / N), phase = PHASES[k % count]
        // (PHASES default off,on; idle = engine stopped by the extension, tunnel up).
        // The extension restarts the engine at each slot boundary.
        let file = testQuietFile()
        var quiet = ["NB_TEST_TCP_KEEPALIVE_SEC": "", "NB_TEST_GRPC_KEEPALIVE_SEC": "", "NB_TEST_SIGNAL_WATCHDOG_SEC": "", "NB_TEST_ABLATE": "", "NB_TEST_HB_DYNAMIC": "", "NB_TEST_HB_STALE": "", "NB_TEST_HB_PERIOD_SEC": "", "NB_TEST_HB_CLIENT_PHASE_MS": ""]
        var phase = ""
        if let schedule = testQuietSchedule(file), testQuietPhase(file) != "on" {
            phase = " schedule=\(Int(schedule)) phase=\(testQuietPhase(file))"
            // norelay / nocontrol: core defaults with one sender group removed.
            switch testQuietPhase(file) {
            case "norelay": quiet["NB_TEST_ABLATE"] = "relay"
            case "nocontrol": quiet["NB_TEST_ABLATE"] = "control"
            case "dnsonly": quiet["NB_TEST_ABLATE"] = "dnsonly"
            default: break
            }
        } else {
            if let schedule = testQuietSchedule(file) {
                phase = " schedule=\(Int(schedule)) phase=on"
            }
            for (key, value) in file where quiet[key] != nil {
                quiet[key] = value
            }
        }
        for (key, value) in quiet.sorted(by: { $0.key < $1.key }) {
            envList.put(key, value: value)
        }
        AppLogger.shared.log("LOCAL TEST: quiet\(phase) \(quiet.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }.joined(separator: " "))")

        return envList
    }

    // LOCAL TEST (battery): KEY=VALUE lines of <group>/Library/Caches/test-quiet.
    static func testQuietFile() -> [String: String] {
        var out: [String: String] = [:]
        if let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: GlobalConstants.userPreferencesSuiteName)?
            .appendingPathComponent("Library/Caches/test-quiet"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            for line in text.split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2 {
                    out[parts[0]] = parts[1]
                }
            }
        }
        return out
    }

    // LOCAL TEST (battery): SCHEDULE slot length in seconds, nil when unset.
    static func testQuietSchedule(_ file: [String: String] = testQuietFile()) -> TimeInterval? {
        guard let value = file["SCHEDULE"].flatMap(TimeInterval.init), value >= 60 else { return nil }
        return value
    }

    // LOCAL TEST (battery): SCHEDULE_OFFSET in seconds shifts the slot boundaries, default 0.
    static func testQuietOffset(_ file: [String: String] = testQuietFile()) -> TimeInterval {
        return file["SCHEDULE_OFFSET"].flatMap(TimeInterval.init) ?? 0
    }

    // LOCAL TEST (battery): PHASES comma list (off, on, idle), default off,on.
    static func testQuietPhases(_ file: [String: String] = testQuietFile()) -> [String] {
        let phases = (file["PHASES"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return phases.isEmpty ? ["off", "on"] : phases
    }

    // LOCAL TEST (battery): phase of the wall-clock slot, "" without SCHEDULE. A small margin
    // keeps a timer that fires right on the boundary in the new slot.
    static func testQuietPhase(_ file: [String: String] = testQuietFile(), at date: Date = Date()) -> String {
        guard let schedule = testQuietSchedule(file) else { return "" }
        let phases = testQuietPhases(file)
        let slot = Int(floor((date.timeIntervalSince1970 - testQuietOffset(file) + 2) / schedule))
        return phases[slot % phases.count]
    }
}
