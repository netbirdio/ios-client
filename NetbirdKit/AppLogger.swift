//
//  AppLogger.swift
//  NetBird
//

import Foundation

/// Unified logger that writes to the shared app group container.
/// Logs from both main app and network extension are written to the same file.
public class AppLogger {
    public static let shared = AppLogger()

    private let logFileName = "swift-log.log"
    private let maxLogSize: UInt64 = 100 * 1024  // 100 KB
    private let queue = DispatchQueue(label: "io.netbird.logger", qos: .utility)
    private var fileHandle: FileHandle?
    private var logFileURL: URL?
    private var isReady = false
    private var bytesSinceLastSync = 0
    private var syncWorkItem: DispatchWorkItem?
    private let syncByteThreshold = 16 * 1024
    private let syncInterval: TimeInterval = 2
    private let setupSemaphore = DispatchSemaphore(value: 0)

    private let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withFullTime, .withFractionalSeconds]
        return formatter
    }()

    /// Folder for the three log files: logfile.log (Go), swift-log.log (this
    /// logger) and netbird.err (Go stderr, see GoCrashCapture). They stay side
    /// by side because the debug bundle looks for the other two next to
    /// logfile.log. The folder is Library/Logs in the app group container, the
    /// only part of it `devicectl device copy from` can read, so the logs can be
    /// pulled off a device. Falls back to the container root, where the logs
    /// used to live, if the folder cannot be created; nil without an app group.
    public static let logDirectoryURL: URL? = {
        let fileManager = FileManager.default
        guard let groupURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: GlobalConstants.userPreferencesSuiteName) else {
            return nil
        }
        let logsURL = groupURL.appendingPathComponent("Library/Logs", isDirectory: true)
        do {
            try fileManager.createDirectory(at: logsURL, withIntermediateDirectories: true)
        } catch {
            print("AppLogger: Failed to create \(logsURL.path), logging to the container root: \(error)")
            return groupURL
        }
        // Logs written by earlier versions at the container root are no longer
        // read by anything; remove them so they do not linger.
        for name in ["logfile.log", "swift-log.log", "netbird.err"] {
            try? fileManager.removeItem(at: groupURL.appendingPathComponent(name))
        }
        return logsURL
    }()

    private init() {
        // Setup file logging asynchronously to avoid blocking main thread
        queue.async { [weak self] in
            self?.setupLogFile()
        }
    }

    /// Opens swift-log.log for appending in the log folder, falling back to
    /// Documents where there is no app group. Signals `setupSemaphore` when done,
    /// whether or not the file could be opened.
    private func setupLogFile() {
        let fileManager = FileManager.default
        var containerURL: URL?

        // Try app group container first
        if let logsURL = AppLogger.logDirectoryURL {
            containerURL = logsURL
        } else if let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            // Fallback to documents directory (works on Mac Catalyst)
            containerURL = documentsURL
        }

        guard let baseURL = containerURL else {
            print("AppLogger: No writable container found")
            setupSemaphore.signal()
            return
        }

        // Ensure directory exists
        if !fileManager.fileExists(atPath: baseURL.path) {
            do {
                try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
            } catch {
                print("AppLogger: Failed to create directory: \(error)")
                setupSemaphore.signal()
                return
            }
        }

        logFileURL = baseURL.appendingPathComponent(logFileName)
        guard let url = logFileURL else {
            setupSemaphore.signal()
            return
        }

        if !fileManager.fileExists(atPath: url.path) {
            let created = fileManager.createFile(atPath: url.path, contents: nil)
            if !created {
                print("AppLogger: Failed to create log file at \(url.path)")
                setupSemaphore.signal()
                return
            }
        }

        do {
            fileHandle = try FileHandle(forWritingTo: url)
            fileHandle?.seekToEndOfFile()
            isReady = true
        } catch {
            print("AppLogger: Failed to open log file: \(error)")
        }
        setupSemaphore.signal()
    }

    /// Enqueues a timestamped diagnostic message for persistent logging.
    public func log(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        let fileName = (file as NSString).lastPathComponent
        let timestamp = iso8601Formatter.string(from: Date())
        let logMessage = "[\(timestamp)] [\(fileName):\(line)] \(message)\n"

        print(logMessage, terminator: "")

        queue.async { [weak self] in
            self?.writeToFile(logMessage)
        }
    }

    /// Appends one encoded message and schedules or performs a durability sync.
    private func writeToFile(_ message: String) {
        guard isReady, let data = message.data(using: .utf8) else { return }

        rotateLogIfNeeded()

        fileHandle?.write(data)
        bytesSinceLastSync += data.count
        if bytesSinceLastSync >= syncByteThreshold {
            synchronizePendingData()
        } else if syncWorkItem == nil {
            scheduleSync()
        }
    }

    /// Schedules a delayed file sync when the byte threshold has not been reached.
    private func scheduleSync() {
        let workItem = DispatchWorkItem { [weak self] in
            self?.syncWorkItem = nil
            self?.synchronizePendingData()
        }
        syncWorkItem = workItem
        queue.asyncAfter(deadline: .now() + syncInterval, execute: workItem)
    }

    /// Flushes buffered log bytes to durable storage and retains failed work for retry.
    private func synchronizePendingData() {
        guard bytesSinceLastSync > 0, let fileHandle else { return }

        do {
            try fileHandle.synchronize()
            bytesSinceLastSync = 0
            syncWorkItem?.cancel()
            syncWorkItem = nil
        } catch {
            // Keep the pending byte count intact and retry even if no more logs arrive.
            if syncWorkItem == nil {
                scheduleSync()
            }
        }
    }

    /// Recreates the log file when it exceeds the configured size limit.
    private func rotateLogIfNeeded() {
        guard let url = logFileURL else { return }

        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let fileSize = attributes[.size] as? UInt64, fileSize > maxLogSize {
                fileHandle?.closeFile()
                try FileManager.default.removeItem(at: url)
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                    print("AppLogger: Failed to create rotated log file")
                    isReady = false
                    return
                }
                fileHandle = try FileHandle(forWritingTo: url)
                syncWorkItem?.cancel()
                syncWorkItem = nil
                bytesSinceLastSync = 0
            }
        } catch {
            print("AppLogger: Failed to rotate log: \(error)")
            isReady = false
            fileHandle = nil
        }
    }

    /// Removes existing log contents and creates a fresh writable log file.
    public func clearLogs() {
        queue.async { [weak self] in
            guard let url = self?.logFileURL else { return }
            do {
                self?.fileHandle?.closeFile()
                try FileManager.default.removeItem(at: url)
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                    print("AppLogger: Failed to create cleared log file")
                    self?.isReady = false
                    return
                }
                self?.fileHandle = try FileHandle(forWritingTo: url)
                self?.syncWorkItem?.cancel()
                self?.syncWorkItem = nil
                self?.bytesSinceLastSync = 0
            } catch {
                print("AppLogger: Failed to clear logs: \(error)")
                self?.isReady = false
                self?.fileHandle = nil
            }
        }
    }

    /// The Swift log file, once set up and present; waits up to 2 s for setup.
    public static func getLogFileURL() -> URL? {
        // Wait for setup to complete (with timeout to avoid blocking forever)
        _ = shared.setupSemaphore.wait(timeout: .now() + 2.0)
        shared.setupSemaphore.signal()  // Re-signal for future calls

        guard let url = shared.logFileURL,
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }

    /// The Go client log, logfile.log, in the log folder or, without an app
    /// group, in Documents. Nil until the extension has created it.
    public static func getGoLogFileURL() -> URL? {
        let fileManager = FileManager.default
        // Try app group first
        if let logsURL = AppLogger.logDirectoryURL {
            let url = logsURL.appendingPathComponent("logfile.log")
            if fileManager.fileExists(atPath: url.path) {
                return url
            }
        }
        // Fallback to documents
        if let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            let url = documentsURL.appendingPathComponent("logfile.log")
            if fileManager.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }
}
