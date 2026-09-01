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

    private init() {
        // Setup file logging asynchronously to avoid blocking main thread
        queue.async { [weak self] in
            self?.setupLogFile()
        }
    }

    private func setupLogFile() {
        let fileManager = FileManager.default
        var containerURL: URL?

        // Try app group container first
        if let groupURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: GlobalConstants.userPreferencesSuiteName) {
            containerURL = groupURL
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

    public func log(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        let fileName = (file as NSString).lastPathComponent
        let timestamp = iso8601Formatter.string(from: Date())
        let logMessage = "[\(timestamp)] [\(fileName):\(line)] \(message)\n"

        print(logMessage, terminator: "")

        queue.async { [weak self] in
            self?.writeToFile(logMessage)
        }
    }

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

    private func scheduleSync() {
        let workItem = DispatchWorkItem { [weak self] in
            self?.syncWorkItem = nil
            self?.synchronizePendingData()
        }
        syncWorkItem = workItem
        queue.asyncAfter(deadline: .now() + syncInterval, execute: workItem)
    }

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

    public static func getGoLogFileURL() -> URL? {
        let fileManager = FileManager.default
        // Try app group first
        if let groupURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: GlobalConstants.userPreferencesSuiteName) {
            let url = groupURL.appendingPathComponent("logfile.log")
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
