//
//  ProfileLayoutMigration.swift
//  NetBird
//
//  One-time migration from the legacy Swift directory-per-name profile layout
//  to the Go ServiceManager layout used by NetBirdSDK.
//
//  Legacy layout (directory = profile name):
//      <container>/profiles/profiles.json        { activeProfile, deletedProfiles }
//      <container>/profiles/<name>/netbird.cfg   (holds auth tokens)
//      <container>/profiles/<name>/state.json
//      <container>/profiles/<name>/netbird_server_url
//
//  Go layout (filename stem = ID, display name inside the config):
//      <container>/netbird.cfg                    default profile config
//      <container>/state.json                     default profile state
//      <container>/active_profile.json            { "name": <id>, "username": "ios" }
//      <container>/profiles/<id>.json             non-default config (with "Name")
//      <container>/profiles/<id>.state.json
//
//  We reuse the legacy name as the ID (every legacy name matches the Go
//  filename-stem rules), so the active selection stays valid and the existing
//  ID-keyed connection cache entries remain correct.
//

import Foundation

#if os(iOS)

enum ProfileLayoutMigration {

    private static let markerName = "profiles_migrated_to_go_v1"
    private static let defaultName = "default"
    private static let legacyConfigName = "netbird.cfg"
    private static let legacyStateName = "state.json"
    private static let legacyServerURLName = "netbird_server_url"

    private struct LegacyMeta: Decodable {
        let activeProfile: String?
        let deletedProfiles: [String]?
    }

    /// Runs the migration once. Idempotent: guarded by a marker file and safe
    /// to re-run after a partial failure.
    ///
    /// The app and the network extension are separate processes sharing the App
    /// Group container and may both reach this on first launch (e.g. on-demand
    /// VPN). An NSFileCoordinator write barrier serializes them; the marker is
    /// re-checked inside the barrier (double-checked) so only one process
    /// performs the work.
    static func runIfNeeded(configDir: String) {
        let markerPath = (configDir as NSString).appendingPathComponent(markerName)
        if FileManager.default.fileExists(atPath: markerPath) { return }

        let coordinator = NSFileCoordinator()
        var coordError: NSError?
        coordinator.coordinate(writingItemAt: URL(fileURLWithPath: configDir), options: [], error: &coordError) { _ in
            performMigration(configDir: configDir, markerPath: markerPath)
        }
        if let coordError {
            AppLogger.shared.log("ProfileLayoutMigration: coordination failed: \(coordError)")
        }
    }

    private static func performMigration(configDir: String, markerPath: String) {
        let fm = FileManager.default
        // Re-check inside the barrier: another process may have migrated while
        // we waited for the coordinated write.
        if fm.fileExists(atPath: markerPath) { return }

        let profilesDir = (configDir as NSString).appendingPathComponent("profiles")
        let legacyMetaPath = (profilesDir as NSString).appendingPathComponent("profiles.json")

        // Legacy layout present iff profiles.json exists or there is at least
        // one subdirectory under profiles/. Fresh installs and pre-multiprofile
        // (root-only) installs have neither and need no data movement.
        guard fm.fileExists(atPath: legacyMetaPath) || hasSubdirectory(profilesDir) else {
            _ = writeMarker(markerPath) // nothing to migrate; harmless to retry if this fails
            return
        }

        AppLogger.shared.log("ProfileLayoutMigration: starting legacy → Go layout migration")

        let meta = readLegacyMeta(legacyMetaPath)
        let deleted = Set(meta?.deletedProfiles ?? [])
        let activeNameRaw = meta?.activeProfile ?? ""
        let activeName = activeNameRaw.isEmpty ? defaultName : activeNameRaw

        var allSucceeded = true
        let subdirs = (try? fm.contentsOfDirectory(atPath: profilesDir)) ?? []
        for entry in subdirs {
            let entryPath = (profilesDir as NSString).appendingPathComponent(entry)
            guard isDirectory(entryPath) else { continue } // skip profiles.json itself
            if deleted.contains(entry) {
                try? fm.removeItem(atPath: entryPath) // best-effort tombstone cleanup
                continue
            }
            if !migrateOne(name: entry, sourceDir: entryPath, configDir: configDir, profilesDir: profilesDir) {
                allSucceeded = false
            }
        }

        // Only finalize (write active state, clean up, drop the marker) when every
        // profile migrated cleanly. On any failure we leave the legacy files and
        // the marker untouched so the next launch retries — the per-profile steps
        // are idempotent, so a retry re-runs safely.
        guard allSucceeded else {
            AppLogger.shared.log("ProfileLayoutMigration: incomplete — leaving legacy data in place, will retry next launch")
            return
        }

        // Record the active profile. If it was deleted, fall back to default.
        let activeID = (activeName == defaultName || deleted.contains(activeName)) ? defaultName : activeName
        guard writeActiveProfile(id: activeID, configDir: configDir) else {
            AppLogger.shared.log("ProfileLayoutMigration: active-profile write failed, will retry next launch")
            return
        }

        cleanupLegacy(profilesDir: profilesDir)
        if writeMarker(markerPath) {
            AppLogger.shared.log("ProfileLayoutMigration: completed (active=\(activeID))")
        } else {
            // Data is fully migrated; only the marker failed. The next launch
            // re-runs harmlessly (idempotent) until the marker sticks.
            AppLogger.shared.log("ProfileLayoutMigration: migrated (active=\(activeID)) but marker write failed; will re-run idempotently")
        }
    }

    // MARK: - Per-profile migration

    /// Migrates a single legacy profile directory. Returns false on a hard
    /// failure (config could not be read or written) so the caller can defer
    /// finalization and retry on the next launch. State-file moves and cache
    /// seeding are best-effort and never fail the migration.
    private static func migrateOne(name: String, sourceDir: String, configDir: String, profilesDir: String) -> Bool {
        let fm = FileManager.default
        let srcConfig = (sourceDir as NSString).appendingPathComponent(legacyConfigName)
        let srcState = (sourceDir as NSString).appendingPathComponent(legacyStateName)
        let srcURLFile = (sourceDir as NSString).appendingPathComponent(legacyServerURLName)

        let isDefault = (name == defaultName)
        let id = isDefault ? defaultName : name
        let serverURL = readServerURL(srcURLFile)

        // Seed the connection cache so the management URL survives even for
        // logged-out profiles whose config we cannot recover.
        if let url = serverURL, !url.isEmpty {
            ProfileConnectionCache().saveManagementURL(url, forID: id)
        }

        let destConfig: String
        let destState: String
        if isDefault {
            destConfig = (configDir as NSString).appendingPathComponent(legacyConfigName)
            destState = (configDir as NSString).appendingPathComponent(legacyStateName)
        } else {
            try? fm.createDirectory(atPath: profilesDir, withIntermediateDirectories: true)
            destConfig = (profilesDir as NSString).appendingPathComponent("\(id).json")
            destState = (profilesDir as NSString).appendingPathComponent("\(id).state.json")
        }

        // --- Config ---
        if fm.fileExists(atPath: srcConfig) {
            guard let data = fm.contents(atPath: srcConfig) else {
                AppLogger.shared.log("ProfileLayoutMigration: cannot read config for '\(id)'")
                return false
            }
            if var dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                // Preserve every field (incl. auth tokens) and stamp the display
                // name. The default profile keeps its implicit "default" name.
                if !isDefault { dict["Name"] = name }
                guard writeJSONObject(dict, to: destConfig) else {
                    AppLogger.shared.log("ProfileLayoutMigration: cannot write config for '\(id)'")
                    return false
                }
            } else {
                // Present but unparseable: copy the bytes verbatim so auth tokens
                // are never lost. Go falls back to the filename stem for the name.
                guard writeData(data, to: destConfig) else {
                    AppLogger.shared.log("ProfileLayoutMigration: cannot write raw config for '\(id)'")
                    return false
                }
            }
        } else {
            // No config (logged-out profile). For non-default profiles we still
            // create a minimal config so the profile remains visible; for the
            // default profile we instead clear any stale root config so it shows
            // as logged out.
            if isDefault {
                if let url = serverURL, !url.isEmpty {
                    guard writeJSONObject(["ManagementURL": managementURLObject(url)], to: destConfig) else {
                        return false
                    }
                } else {
                    try? fm.removeItem(atPath: destConfig) // best-effort clear
                }
            } else {
                var dict: [String: Any] = ["Name": name]
                if let url = serverURL, !url.isEmpty {
                    dict["ManagementURL"] = managementURLObject(url)
                }
                guard writeJSONObject(dict, to: destConfig) else { return false }
            }
        }

        // --- State (best-effort; runtime state is regenerable) ---
        if fm.fileExists(atPath: srcState) {
            try? fm.removeItem(atPath: destState)
            do {
                try fm.moveItem(atPath: srcState, toPath: destState)
            } catch {
                AppLogger.shared.log("ProfileLayoutMigration: state move failed for '\(id)': \(error)")
            }
        } else if isDefault {
            // Default logged out / never connected: drop stale root state.
            try? fm.removeItem(atPath: destState)
        }

        return true
    }

    // MARK: - active_profile.json

    private static func writeActiveProfile(id: String, configDir: String) -> Bool {
        let path = (configDir as NSString).appendingPathComponent("active_profile.json")
        // Mirrors profilemanager.ActiveProfileState: the JSON key is "name" but
        // it stores the ID. Username is required to be non-empty for non-default.
        let state: [String: Any] = [
            "name": id,
            "username": id == defaultName ? "" : "ios",
        ]
        return writeJSONObject(state, to: path)
    }

    // MARK: - Cleanup

    private static func cleanupLegacy(profilesDir: String) {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(atPath: profilesDir)) ?? []
        for entry in entries {
            let path = (profilesDir as NSString).appendingPathComponent(entry)
            // Remove the old per-name directories and the legacy meta file, but
            // keep the new flat <id>.json / <id>.state.json files we just wrote.
            if isDirectory(path) || entry == "profiles.json" {
                try? fm.removeItem(atPath: path)
            }
        }
    }

    // MARK: - Helpers

    private static func readLegacyMeta(_ path: String) -> LegacyMeta? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(LegacyMeta.self, from: data)
    }

    private static func readServerURL(_ path: String) -> String? {
        guard let url = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Builds the nested {Scheme, Host, Path} object the Go SDK expects when
    /// deserializing a url.URL. Host includes the port (e.g. "host:443").
    private static func managementURLObject(_ urlString: String) -> [String: Any] {
        guard let parsed = URL(string: urlString) else {
            return ["Scheme": "https", "Host": urlString, "Path": ""]
        }
        var host = parsed.host ?? ""
        if let port = parsed.port { host += ":\(port)" }
        return [
            "Scheme": parsed.scheme ?? "https",
            "Host": host,
            "Path": parsed.path,
        ]
    }

    private static func writeJSONObject(_ dict: [String: Any], to path: String) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: []) else { return false }
        return writeData(data, to: path)
    }

    private static func writeData(_ data: Data, to path: String) -> Bool {
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func hasSubdirectory(_ dir: String) -> Bool {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return entries.contains { isDirectory((dir as NSString).appendingPathComponent($0)) }
    }

    private static func writeMarker(_ path: String) -> Bool {
        return FileManager.default.createFile(atPath: path, contents: Data())
    }
}

#endif
