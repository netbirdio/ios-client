//
//  SSHSessionManager.swift
//  NetbirdNetworkExtension
//

import Foundation
import NetBirdSDK

/// Bridges the gomobile `SSHClient` (which only runs where the live, tunnel-bound
/// `NetBirdSDKClient` lives, i.e. this extension process) to the main app, which
/// has no direct access to that Client. The main app drives a session via
/// `PacketTunnelProvider.handleAppMessage` using long-poll requests (see `poll`);
/// there is no persistent connection between the two processes.
/// Posted via Darwin notification center when JWT browser auth is needed.
private let sshJWTNotificationName = "io.netbird.app.ssh.jwtRequired"
private let sshJWTURLDefaultsKey   = "io.netbird.ssh.jwtURL"
private let sshJWTCodeDefaultsKey  = "io.netbird.ssh.jwtUserCode"
private let sshAppGroupID          = "group.io.netbird.app"

/// Handles the Go URLOpener callback for NetBird SSH servers that require JWT.
/// Writes the auth URL to the terminal stream and notifies the main app to open it.
private final class SSHJWTURLOpener: NSObject, NetBirdSDKURLOpenerProtocol {
    private let onTerminalOutput: (Data) -> Void

    init(onTerminalOutput: @escaping (Data) -> Void) {
        self.onTerminalOutput = onTerminalOutput
    }

    func open(_ url: String?, userCode: String?) {
        guard let url, !url.isEmpty else { return }
        let code = userCode ?? ""

        let msg =
            "\r\n\u{1b}[33m" +
            "NetBird SSH requires browser authentication.\r\n" +
            "User code:  \u{1b}[1m\(code)\u{1b}[0m\u{1b}[33m\r\n" +
            "URL: \(url)\r\n" +
            "Opening browser — complete auth to continue…\r\n" +
            "\u{1b}[0m"
        onTerminalOutput(Data(msg.utf8))

        UserDefaults(suiteName: sshAppGroupID)?.set(url,  forKey: sshJWTURLDefaultsKey)
        UserDefaults(suiteName: sshAppGroupID)?.set(code, forKey: sshJWTCodeDefaultsKey)

        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(sshJWTNotificationName as CFString),
            nil, nil, true
        )
    }

    func onLoginSuccess() {}
}

final class SSHSession: NSObject, NetBirdSDKSSHTerminalListenerProtocol {
    private let sshClient: NetBirdSDKSSHClient
    private let lock = NSLock()
    private let dataAvailable = DispatchSemaphore(value: 0)

    private var pendingData = Data()
    private var closedReason: String?
    private var errorMessage: String?

    init?(nbClient: NetBirdSDKClient) {
        guard let sshClient = NetBirdSDKNewSSHClient(nbClient) else { return nil }
        self.sshClient = sshClient
        super.init()
        sshClient.setListener(self)

        let urlOpener = SSHJWTURLOpener { [weak self] data in
            self?.onData(data)
        }
        sshClient.setURLOpener(urlOpener)
    }

    func connect(host: String, port: Int, user: String, password: String, cols: Int, rows: Int) -> String? {
        do {
            try sshClient.connect(host, port: port, user: user, password: password)
            try sshClient.startSession(cols, rows: rows)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Connects using NetBird JWT auth (no detection, no password). Use for peers
    /// with SSH enabled in the NetBird dashboard.
    func connectNetBirdPeer(host: String, port: Int, user: String, cols: Int, rows: Int) -> String? {
        do {
            try sshClient.connectNetBirdPeer(host, port: port, user: user)
            try sshClient.startSession(cols, rows: rows)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func write(_ data: Data) -> String? {
        do {
            try sshClient.write(data)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func resize(cols: Int, rows: Int) -> String? {
        do {
            try sshClient.resize(cols, rows: rows)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func close() {
        try? sshClient.close()
    }

    /// Blocks the calling thread until output is available, the session closes,
    /// or `timeout` elapses, then returns whatever has accumulated since the
    /// last poll. Intended to be called from a background queue only.
    func poll(timeout: TimeInterval) -> SSHPollResult {
        _ = dataAvailable.wait(timeout: .now() + timeout)

        lock.lock()
        defer { lock.unlock() }

        let chunk = pendingData
        pendingData = Data()

        if let errorMessage {
            return SSHPollResult(dataBase64: chunk.base64EncodedString(), status: "error", reason: errorMessage)
        }
        if let closedReason {
            return SSHPollResult(dataBase64: chunk.base64EncodedString(), status: "closed", reason: closedReason)
        }
        return SSHPollResult(dataBase64: chunk.base64EncodedString(), status: "connected", reason: nil)
    }

    // MARK: NetBirdSDKSSHTerminalListenerProtocol

    func onConnected() {
        // Connection success is surfaced synchronously via `connect(...)`'s
        // returned error (nil == success); no separate signal needed here.
    }

    func onData(_ data: Data?) {
        guard let data else { return }
        lock.lock()
        pendingData.append(data)
        lock.unlock()
        dataAvailable.signal()
    }

    func onClose(_ reason: String?) {
        lock.lock()
        closedReason = reason ?? "closed"
        lock.unlock()
        dataAvailable.signal()
    }

    func onError(_ message: String?) {
        lock.lock()
        errorMessage = message ?? "unknown error"
        lock.unlock()
        dataAvailable.signal()
    }
}

struct SSHPollResult: Codable {
    var dataBase64: String
    var status: String
    var reason: String?
}

/// Owns all active SSH sessions for the lifetime of the extension process,
/// keyed by an opaque session id chosen by the main app.
final class SSHSessionManager {
    private let lock = NSLock()
    private var sessions: [String: SSHSession] = [:]

    func connect(sessionID: String, nbClient: NetBirdSDKClient, host: String, port: Int, user: String, password: String, cols: Int, rows: Int) -> String? {
        guard let session = SSHSession(nbClient: nbClient) else {
            return "failed to create SSH client"
        }
        lock.lock()
        sessions[sessionID] = session
        lock.unlock()

        if let error = session.connect(host: host, port: port, user: user, password: password, cols: cols, rows: rows) {
            lock.lock()
            sessions.removeValue(forKey: sessionID)
            lock.unlock()
            return error
        }
        return nil
    }

    func connectNetBirdPeer(sessionID: String, nbClient: NetBirdSDKClient, host: String, port: Int, user: String, cols: Int, rows: Int) -> String? {
        guard let session = SSHSession(nbClient: nbClient) else {
            return "failed to create SSH client"
        }
        lock.lock()
        sessions[sessionID] = session
        lock.unlock()

        if let error = session.connectNetBirdPeer(host: host, port: port, user: user, cols: cols, rows: rows) {
            lock.lock()
            sessions.removeValue(forKey: sessionID)
            lock.unlock()
            return error
        }
        return nil
    }

    func write(sessionID: String, data: Data) -> String? {
        guard let session = session(for: sessionID) else { return "session not found" }
        return session.write(data)
    }

    func resize(sessionID: String, cols: Int, rows: Int) -> String? {
        guard let session = session(for: sessionID) else { return "session not found" }
        return session.resize(cols: cols, rows: rows)
    }

    func poll(sessionID: String, timeout: TimeInterval) -> SSHPollResult {
        guard let session = session(for: sessionID) else {
            return SSHPollResult(dataBase64: "", status: "closed", reason: "session not found")
        }
        let result = session.poll(timeout: timeout)
        if result.status != "connected" {
            removeSession(sessionID)
        }
        return result
    }

    func close(sessionID: String) {
        guard let session = session(for: sessionID) else { return }
        session.close()
        removeSession(sessionID)
    }

    private func session(for sessionID: String) -> SSHSession? {
        lock.lock()
        defer { lock.unlock() }
        return sessions[sessionID]
    }

    private func removeSession(_ sessionID: String) {
        lock.lock()
        sessions.removeValue(forKey: sessionID)
        lock.unlock()
    }
}
