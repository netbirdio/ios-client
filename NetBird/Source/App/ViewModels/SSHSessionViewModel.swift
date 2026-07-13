//
//  SSHSessionViewModel.swift
//  NetBird
//

import Foundation
import Combine

enum SSHConnectionState: Equatable {
    case connecting
    case connected
    case closed(reason: String)
    case failed(message: String)
}

/// Drives one SSH session through the long-poll IPC bridge to the
/// NetbirdNetworkExtension process (see `NetbirdKit/SSHIPC.swift`). Owns the
/// session id and the poll loop; the hosting view feeds it terminal input and
/// consumes its output via `onOutput`.
@MainActor
final class SSHSessionViewModel: ObservableObject, Identifiable {
    var id: String { sessionID }
    let sessionID = UUID().uuidString
    let host: String
    let port: Int
    let user: String
    let password: String
    /// When true, uses `ConnectNetBirdPeer` (JWT, no detection) instead of `Connect`.
    let isNetBirdPeer: Bool

    @Published private(set) var state: SSHConnectionState = .connecting
    @Published private(set) var canReconnect = false

    var onOutput: ((Data) -> Void)?

    private let networkExtensionAdapter: NetworkExtensionAdapter
    private var isPolling = false
    private var isUserInitiatedStop = false
    private var lastCols = 80
    private var lastRows = 24

    private let pollTimeoutMs = 25_000

    // Rolling output buffer so the terminal can be replayed when the WebView
    // is recreated (e.g. returning to an active session from the sessions list).
    private var outputBuffer = Data()
    private let outputBufferMaxSize = 128 * 1024

    init(networkExtensionAdapter: NetworkExtensionAdapter, host: String, port: Int, user: String, password: String, isNetBirdPeer: Bool = false) {
        self.networkExtensionAdapter = networkExtensionAdapter
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.isNetBirdPeer = isNetBirdPeer
    }

    /// Called by the terminal view when xterm.js signals it is ready.
    /// - If already connected: replays buffered output and resizes the PTY.
    /// - Otherwise: starts the connection.
    func onTerminalReady(cols: Int, rows: Int) {
        if case .connected = state {
            resize(cols: cols, rows: rows)
            if !outputBuffer.isEmpty {
                onOutput?(outputBuffer)
            }
            return
        }
        start(cols: cols, rows: rows)
    }

    func start(cols: Int, rows: Int) {
        lastCols = cols
        lastRows = rows
        isUserInitiatedStop = false
        canReconnect = false
        state = .connecting

        if isNetBirdPeer {
            networkExtensionAdapter.sshConnectNetBirdPeer(sessionID: sessionID, host: host, port: port, user: user, cols: cols, rows: rows) { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }
                    if let error {
                        self.state = .failed(message: error)
                        self.canReconnect = true
                        return
                    }
                    self.state = .connected
                    self.beginPolling()
                }
            }
            return
        }

        networkExtensionAdapter.sshConnect(sessionID: sessionID, host: host, port: port, user: user, password: password, cols: cols, rows: rows) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.state = .failed(message: error)
                    self.canReconnect = true
                    return
                }
                self.state = .connected
                self.beginPolling()
            }
        }
    }

    func reconnect() {
        outputBuffer.removeAll()
        canReconnect = false
        start(cols: lastCols, rows: lastRows)
    }

    func write(_ data: Data) {
        networkExtensionAdapter.sshWrite(sessionID: sessionID, data: data) { error in
            if let error {
                AppLogger.shared.log("SSH write failed: \(error)")
            }
        }
    }

    func resize(cols: Int, rows: Int) {
        lastCols = cols
        lastRows = rows
        networkExtensionAdapter.sshResize(sessionID: sessionID, cols: cols, rows: rows) { _ in }
    }

    func stop() {
        isUserInitiatedStop = true
        canReconnect = false
        isPolling = false
        networkExtensionAdapter.sshClose(sessionID: sessionID)
    }

    private func beginPolling() {
        guard !isPolling else { return }
        isPolling = true
        pollOnce()
    }

    private func pollOnce() {
        guard isPolling else { return }
        networkExtensionAdapter.sshPoll(sessionID: sessionID, timeoutMs: pollTimeoutMs) { [weak self] result in
            Task { @MainActor in
                guard let self, self.isPolling else { return }

                if let data = Data(base64Encoded: result.dataBase64), !data.isEmpty {
                    self.appendToBuffer(data)
                    self.onOutput?(data)
                }

                switch result.status {
                case "connected":
                    self.pollOnce()
                case "closed":
                    self.isPolling = false
                    self.state = .closed(reason: result.reason ?? "closed")
                    if !self.isUserInitiatedStop { self.canReconnect = true }
                default:
                    self.isPolling = false
                    self.state = .failed(message: result.reason ?? "unknown error")
                    if !self.isUserInitiatedStop { self.canReconnect = true }
                }
            }
        }
    }

    private func appendToBuffer(_ data: Data) {
        outputBuffer.append(data)
        if outputBuffer.count > outputBufferMaxSize {
            outputBuffer = Data(outputBuffer.suffix(outputBufferMaxSize))
        }
    }
}
