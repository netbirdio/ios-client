//
//  GoCrashCapture.swift
//  NetBird
//

import Foundation

/// Keeps the Go runtime's crash output around after the process is gone.
///
/// The Go runtime writes panic messages and fatal-error goroutine dumps to fd 2
/// right before it aborts the process. Neither the main app nor the network
/// extension keeps stderr anywhere, and the resulting SIGABRT crash report stops
/// at the Go stack switch (`runtime.asmcgocall`) without the panicking Go frames —
/// so after a crash this file is the only place the panic reason can be recovered
/// from. `redirect()` points fd 2 at "netbird.err" in the app group container,
/// next to logfile.log, where the debug bundle generator already picks it up
/// (see BundleGenerator.addLogfile in netbird-core).
///
/// Both processes append to the same file. `takeUnreportedCrashOutput()` lets the
/// main app forward what was written since its previous report without truncating
/// the file, which the debug bundle still relies on.
public enum GoCrashCapture {
    private static let fileName = "netbird.err"
    private static let maxFileSize: UInt64 = 5 * 1024 * 1024
    /// Crashlytics keeps at most 64 KB of logs per session; stay under it so the
    /// panic header at the top of the dump is never the part that gets dropped.
    private static let maxReportSize = 48 * 1024
    private static let reportedOffsetKey = "io.netbird.goCrashCapture.reportedOffset"
    private static let crashMarkers = ["panic:", "fatal error:"]

    private static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: GlobalConstants.userPreferencesSuiteName)?
            .appendingPathComponent(fileName)
    }

    private static let redirectOnce: Void = {
        let fileManager = FileManager.default
        guard let errLogURL = fileURL else {
            AppLogger.shared.log("stderr redirect: app group container unavailable")
            return
        }

        if let attrs = try? fileManager.attributesOfItem(atPath: errLogURL.path),
           let size = attrs[.size] as? UInt64, size > 0 {
            // Surface a previous session's crash output before appending to it.
            AppLogger.shared.log("stderr redirect: netbird.err has \(size) bytes from a previous session (possible crash dump)")
            // Cap growth across sessions: reset once it grows beyond 5 MB.
            if size > maxFileSize {
                AppLogger.shared.log("stderr redirect: netbird.err exceeds 5 MB cap, resetting")
                try? fileManager.removeItem(at: errLogURL)
            }
        }

        let fd = open(errLogURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else {
            AppLogger.shared.log("stderr redirect: failed to open \(errLogURL.path), errno=\(errno)")
            return
        }
        dup2(fd, STDERR_FILENO)
        if fd != STDERR_FILENO {
            close(fd)
        }

        let marker = "\n=== stderr redirect active pid=\(getpid()) at \(ISO8601DateFormatter().string(from: Date())) ===\n"
        marker.withCString { _ = write(STDERR_FILENO, $0, strlen($0)) }
        AppLogger.shared.log("stderr redirect: fd 2 -> netbird.err in app group container")
    }()

    /// Redirects this process's stderr into netbird.err. Safe to call repeatedly;
    /// only the first call has an effect. Must run before any Go SDK call so a
    /// panic during startup is captured too.
    public static func redirect() {
        _ = redirectOnce
    }

    /// Returns the crash output appended to netbird.err since the previous call,
    /// or nil when nothing new looks like a Go panic or fatal error. The consumed
    /// range is remembered so the same dump is never reported twice, even though
    /// the file itself is left untouched.
    public static func takeUnreportedCrashOutput() -> String? {
        guard let errLogURL = fileURL,
              let handle = try? FileHandle(forReadingFrom: errLogURL) else {
            return nil
        }
        defer { try? handle.close() }

        guard let fileSize = try? handle.seekToEnd() else { return nil }
        let defaults = UserDefaults.standard
        var reportedOffset = UInt64(max(0, defaults.integer(forKey: reportedOffsetKey)))
        // The file was reset (or replaced) since the last report; start over.
        if reportedOffset > fileSize {
            reportedOffset = 0
        }
        defaults.set(Int(fileSize), forKey: reportedOffsetKey)

        guard fileSize > reportedOffset,
              (try? handle.seek(toOffset: reportedOffset)) != nil,
              let data = try? handle.read(upToCount: min(Int(fileSize - reportedOffset), maxReportSize)),
              let output = String(data: data, encoding: .utf8) else {
            return nil
        }

        guard crashMarkers.contains(where: output.contains) else { return nil }
        return output
    }
}
