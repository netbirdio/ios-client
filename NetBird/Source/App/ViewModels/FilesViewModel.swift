//
//  FilesViewModel.swift
//  NetBird
//
//  Application-side view of the file drop state. All reads and writes go
//  through the extension when its provider session answers, since the engine
//  and the authoritative transfer state live there; when the extension is not
//  running (tunnel down), the same persisted state is read directly through
//  NetBirdSDK so history and settings stay visible offline.
//

#if os(iOS)

import Foundation
import Combine
import NetBirdSDK
import UniformTypeIdentifiers

class FilesViewModel: ObservableObject {

    @Published var transfers: [FileDropTransferInfo] = []
    @Published var searchText: String = ""
    @Published var mode: FileDropMode = .ask

    private weak var adapter: NetworkExtensionAdapter?
    private var timer: Timer?
    private let directQueue = DispatchQueue(label: "io.netbird.filedrop.direct")

    static let outboxSubdir = "filedrop-outbox"

    func bind(adapter: NetworkExtensionAdapter) {
        self.adapter = adapter
    }

    // MARK: - Derived rows

    var filteredTransfers: [FileDropTransferInfo] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return transfers }
        return transfers.filter { matches($0, query: query) }
    }

    /// Incoming offers waiting for an answer, pinned above the log.
    var pendingOffers: [FileDropTransferInfo] {
        filteredTransfers.filter { $0.isAnswerable }
    }

    /// The transfer log grouped by day, newest first, offers excluded.
    var dayGroups: [(label: String, items: [FileDropTransferInfo])] {
        var groups: [(label: String, items: [FileDropTransferInfo])] = []
        for transfer in filteredTransfers where !transfer.isAnswerable {
            let label = FilesViewModel.dayLabel(for: transfer.createdAt)
            if let last = groups.indices.last, groups[last].label == label {
                groups[last].items.append(transfer)
            } else {
                groups.append((label: label, items: [transfer]))
            }
        }
        return groups
    }

    private func matches(_ transfer: FileDropTransferInfo, query: String) -> Bool {
        if transfer.peerName.lowercased().contains(query) { return true }
        if transfer.isText && transfer.text.lowercased().contains(query) { return true }
        return transfer.fileNames.contains { $0.lowercased().contains(query) }
    }

    static func dayLabel(for date: Date?) -> String {
        guard let date = date else { return "Earlier" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }

    // MARK: - Refresh & polling

    func refresh() {
        if let adapter = adapter {
            adapter.fileDropTransfers { [weak self] list in
                if let list = list {
                    DispatchQueue.main.async { self?.apply(list) }
                } else {
                    self?.refreshDirect()
                }
            }
        } else {
            refreshDirect()
        }
        cleanupOutbox()
    }

    private func apply(_ list: [FileDropTransferInfo]) {
        transfers = list
        relocateDelivered(list)
    }

    func refreshMode() {
        if let adapter = adapter {
            adapter.fileDropGetMode { [weak self] value in
                if let value = value, let mode = FileDropMode(rawValue: value) {
                    DispatchQueue.main.async { self?.mode = mode }
                } else {
                    self?.refreshModeDirect()
                }
            }
        } else {
            refreshModeDirect()
        }
    }

    func setMode(_ newMode: FileDropMode) {
        mode = newMode
        if let adapter = adapter {
            adapter.fileDropSetMode(newMode.rawValue) { [weak self] ok in
                if !ok {
                    self?.setModeDirect(newMode)
                }
            }
        } else {
            setModeDirect(newMode)
        }
    }

    func startPolling() {
        stopPolling()
        refresh()
        refreshMode()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Actions

    func accept(_ transfer: FileDropTransferInfo) { action("Accept", id: transfer.id) }
    func decline(_ transfer: FileDropTransferInfo) { action("Decline", id: transfer.id) }
    func stop(_ transfer: FileDropTransferInfo) { action("Stop", id: transfer.id) }
    func remove(_ transfer: FileDropTransferInfo) { action("Remove", id: transfer.id) }

    private func action(_ verb: String, id: String) {
        if let adapter = adapter {
            adapter.fileDropAction(verb, id: id) { [weak self] ok in
                if !ok {
                    self?.actionDirect(verb, id: id)
                } else {
                    self?.refresh()
                }
            }
        } else {
            actionDirect(verb, id: id)
        }
    }

    // MARK: - Sending

    /// Starts a transfer through the extension and reports the transfer ID the
    /// row can follow. Sending needs the engine, so there is no direct path.
    func send(_ request: FileDropSendRequest, completion: @escaping (Result<String, Error>) -> Void) {
        guard let adapter = adapter else {
            completion(.failure(FilesError.notRunning))
            return
        }
        adapter.fileDropSend(request) { response in
            DispatchQueue.main.async {
                guard let response = response else {
                    completion(.failure(FilesError.notRunning))
                    return
                }
                if !response.error.isEmpty {
                    completion(.failure(FilesError.sendFailed(response.error)))
                    return
                }
                completion(.success(response.transferID))
            }
        }
    }

    enum FilesError: LocalizedError {
        case notRunning
        case sendFailed(String)
        case unreadable

        var errorDescription: String? {
            switch self {
            case .notRunning: return "NetBird is not running"
            case .sendFailed(let message): return message
            case .unreadable: return "The selected files could not be read"
            }
        }
    }

    // MARK: - Outgoing staging

    /// Copies the picked files into the shared outbox so the extension can read
    /// them by path for as long as the upload runs: the picker's own access to
    /// the originals ends with the sheet, and the extension could never reach
    /// them anyway.
    static func stageFiles(_ urls: [URL]) -> [FileDropSendFile] {
        guard let container = sharedContainerURL() else { return [] }
        let batchDir = container
            .appendingPathComponent(outboxSubdir, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        let fileManager = FileManager.default
        guard (try? fileManager.createDirectory(at: batchDir, withIntermediateDirectories: true)) != nil else {
            return []
        }

        var staged: [FileDropSendFile] = []
        for url in urls {
            let secured = url.startAccessingSecurityScopedResource()
            defer { if secured { url.stopAccessingSecurityScopedResource() } }

            let destination = batchDir.appendingPathComponent(url.lastPathComponent)
            do {
                try fileManager.copyItem(at: url, to: destination)
            } catch {
                continue
            }

            let attrs = try? fileManager.attributesOfItem(atPath: destination.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            staged.append(FileDropSendFile(
                name: url.lastPathComponent,
                size: size,
                contentType: contentType(for: url),
                path: destination.path
            ))
        }
        return staged
    }

    static func contentType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension),
           let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }

    /// Staged copies must outlive the sheet that created them, so they are
    /// swept by age instead of on dismiss: a day is far beyond any plausible
    /// transfer, while a crashed send never strands its copies forever.
    private func cleanupOutbox() {
        directQueue.async {
            guard let container = FilesViewModel.sharedContainerURL() else { return }
            let outbox = container.appendingPathComponent(FilesViewModel.outboxSubdir, isDirectory: true)
            let fileManager = FileManager.default
            guard let entries = try? fileManager.contentsOfDirectory(
                at: outbox, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }

            let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
            for entry in entries {
                let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let modified = modified, modified < cutoff {
                    try? fileManager.removeItem(at: entry)
                }
            }
        }
    }

    // MARK: - Delivered file relocation

    /// Received files land in the app group container, which nothing outside
    /// the app can browse. Completed transfers are therefore moved into the
    /// app's Documents directory, which Info.plist exposes in the Files app as
    /// the NetBird folder, and the new locations are remembered per transfer
    /// since the Go history keeps pointing at the old ones.
    private static let relocatedKey = "netbird.filedrop.relocated"

    /// Returns where a transfer's received files live now: the relocated
    /// copies when the move already happened, the original delivery paths
    /// otherwise.
    func deliveredURLs(for transfer: FileDropTransferInfo) -> [URL] {
        let map = UserDefaults.standard.dictionary(forKey: FilesViewModel.relocatedKey) as? [String: [String]] ?? [:]
        let paths = map[transfer.id] ?? transfer.deliveredPaths
        return paths.map { URL(fileURLWithPath: $0) }
    }

    private func relocateDelivered(_ list: [FileDropTransferInfo]) {
        directQueue.async {
            let defaults = UserDefaults.standard
            var map = defaults.dictionary(forKey: FilesViewModel.relocatedKey) as? [String: [String]] ?? [:]
            let fileManager = FileManager.default
            guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }

            var changed = false
            for transfer in list where !transfer.outgoing && !transfer.isText
                && transfer.transferState == .completed && !transfer.deliveredPaths.isEmpty {
                if map[transfer.id] != nil { continue }

                var moved: [String] = []
                for path in transfer.deliveredPaths {
                    let source = URL(fileURLWithPath: path)
                    guard fileManager.fileExists(atPath: source.path) else { continue }
                    let destination = FilesViewModel.uniqueDestination(for: source.lastPathComponent, in: documents)
                    do {
                        try fileManager.moveItem(at: source, to: destination)
                        moved.append(destination.path)
                    } catch {
                        AppLogger.shared.log("file drop relocation failed for \(source.lastPathComponent): \(error.localizedDescription)")
                    }
                }
                if !moved.isEmpty {
                    map[transfer.id] = moved
                    changed = true
                }
            }

            let ids = Set(list.map { $0.id })
            let pruned = map.filter { ids.contains($0.key) }
            if pruned.count != map.count {
                map = pruned
                changed = true
            }

            if changed {
                defaults.set(map, forKey: FilesViewModel.relocatedKey)
            }
        }
    }

    private static func uniqueDestination(for name: String, in directory: URL) -> URL {
        let fileManager = FileManager.default
        var candidate = directory.appendingPathComponent(name)
        if !fileManager.fileExists(atPath: candidate.path) {
            return candidate
        }

        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var counter = 2
        repeat {
            let numbered = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            candidate = directory.appendingPathComponent(numbered)
            counter += 1
        } while fileManager.fileExists(atPath: candidate.path)
        return candidate
    }

    // MARK: - Direct (extension not running)

    static func sharedContainerURL() -> URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: GlobalConstants.userPreferencesSuiteName)
    }

    private func withDirectHandle(_ work: @escaping (NetBirdSDKFileDrop) -> Void) {
        directQueue.async {
            guard let container = FilesViewModel.sharedContainerURL() else { return }
            let profileID = ProfileManager.shared.getActiveProfileID()
            var error: NSError?
            guard let handle = NetBirdSDKNewFileDrop(container.path, profileID, &error) else {
                if let error = error {
                    AppLogger.shared.log("file drop direct handle failed: \(error.localizedDescription)")
                }
                return
            }
            work(handle)
            try? handle.close()
        }
    }

    private func refreshDirect() {
        withDirectHandle { [weak self] handle in
            guard let array = handle.transfers() else { return }
            var list: [FileDropTransferInfo] = []
            for i in 0..<array.length() {
                guard let t = array.get(i) else { continue }
                list.append(FileDropTransferInfo(sdk: t))
            }
            DispatchQueue.main.async { self?.apply(list) }
        }
    }

    private func refreshModeDirect() {
        withDirectHandle { [weak self] handle in
            let value = handle.mode()
            guard let mode = FileDropMode(rawValue: value) else { return }
            DispatchQueue.main.async { self?.mode = mode }
        }
    }

    private func setModeDirect(_ newMode: FileDropMode) {
        withDirectHandle { handle in
            try? handle.setMode(newMode.rawValue)
        }
    }

    private func actionDirect(_ verb: String, id: String) {
        withDirectHandle { [weak self] handle in
            switch verb {
            case "Accept":
                try? handle.accept(id)
            case "Decline":
                try? handle.decline(id)
            case "Stop":
                handle.cancel(id)
            case "Remove":
                handle.deleteTransfer(id)
            default:
                break
            }
            DispatchQueue.main.async { self?.refresh() }
        }
    }

}

#endif
