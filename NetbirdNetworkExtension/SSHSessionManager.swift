//
//  SSHSessionManager.swift
//  NetbirdNetworkExtension
//
//  Bridges the gomobile `SSHClient` — which only runs where the live,
//  tunnel-bound `NetBirdSDKClient` exists, i.e. this extension process — to the
//  main app, which has no direct access to that Client. The app drives a
//  session through `PacketTunnelProvider.handleAppMessage` using the commands
//  in `NetbirdKit/SSHProtocol.swift`; there is no persistent connection between
//  the two processes, so output is collected here and handed over on each poll.
//
//  The state machine mirrors the Android client's `SshSession` so both
//  platforms pause, retry and reconnect on the same rules.
//

import Foundation
import NetBirdSDK

/// Posted via Darwin notification center when JWT browser auth is needed.
private let sshJWTNotificationName = "io.netbird.app.ssh.jwtRequired"
private let sshJWTURLDefaultsKey   = "io.netbird.ssh.jwtURL"
private let sshJWTCodeDefaultsKey  = "io.netbird.ssh.jwtUserCode"
private let sshAppGroupID          = "group.io.netbird.app"

/// Marker the Go binding puts in the error when a password would help.
private let sshPasswordRequiredMarker = "netbird-ssh-password-required"
/// Marks a password prompt as following a rejection rather than a first ask.
private let sshRejectedMarker = "rejected"
/// Marker the Go binding puts in the error, followed by ":" and the presented
/// SHA256 fingerprint, when a regular server's host key is not yet trusted.
private let sshHostKeyUnknownMarker = "netbird-ssh-hostkey-unknown"

/// Handles the Go URLOpener callback for NetBird SSH servers that require JWT.
/// Writes the auth URL to the terminal stream and notifies the main app to open
/// it, since the extension has no UI of its own.
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

        let defaults = UserDefaults(suiteName: sshAppGroupID)
        defaults?.set(url,  forKey: sshJWTURLDefaultsKey)
        defaults?.set(code, forKey: sshJWTCodeDefaultsKey)
        defaults?.synchronize()

        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(sshJWTNotificationName as CFString),
            nil, nil, true
        )
    }

    func onLoginSuccess() {}
}

/// One SSH session wired to a gomobile `SSHClient`. Outlives any terminal view
/// in the app: the app may stop polling and come back later, and the connection
/// is unaffected.
///
/// Output is held in a bounded buffer between polls. Unlike Android, where the
/// session lives in the UI process and keeps the whole scrollback, the
/// scrollback here belongs to the app; this buffer only has to survive the gap
/// between two polls, and is capped so a session nobody reads cannot grow
/// without limit inside the extension's tight memory budget.
final class SSHSession: NSObject, NetBirdSDKSSHTerminalListenerProtocol {

    /// Caps the between-poll buffer. Generous enough for a burst of output
    /// across a poll gap, small enough that several idle sessions cannot push
    /// the extension over its memory limit.
    private static let maxPendingBytes = 256 * 1024

    private let sshClient: NetBirdSDKSSHClient
    private let lock = NSLock()
    private let dataAvailable = DispatchSemaphore(value: 0)
    private let connectQueue: DispatchQueue

    let host: String
    let port: Int
    let user: String

    private var pendingData = Data()
    /// True once output had to be dropped, so the app can say so.
    private var pendingTruncated = false

    private var state: SSHSessionState = .connecting
    private var stateMessage = ""
    /// Bumped by every dial; a listener callback from an abandoned attempt
    /// carries an older value and is ignored.
    private var generation: UInt64 = 0
    private var sessionStarted = false
    /// Passwords tried so far, to tell a first prompt from a rejected one.
    private var passwordAttempts = 0
    /// Not final: filled in later when the server turns out to want one. Held
    /// in memory only — a password is never written to disk on either platform.
    private var password = ""

    private var lastCols = 80
    private var lastRows = 24

    init?(nbClient: NetBirdSDKClient, host: String, port: Int, user: String) {
        guard let sshClient = NetBirdSDKNewSSHClient(nbClient) else { return nil }
        self.sshClient = sshClient
        self.host = host
        self.port = port
        self.user = user
        self.connectQueue = DispatchQueue(label: "io.netbird.ssh.session.\(UUID().uuidString)")
        super.init()
        sshClient.setListener(self)

        let urlOpener = SSHJWTURLOpener { [weak self] data in
            self?.onData(data)
        }
        sshClient.setURLOpener(urlOpener)
    }

    /// Points a regular server's host-key verification at the profile's store,
    /// so a trusted key never crosses profiles.
    func setKnownHostsStore(configDir: String, profileID: String) {
        sshClient.setKnownHostsStore(configDir, profileID: profileID)
    }

    // MARK: - Dialling

    /// Kicks off connect + startSession off the caller's thread: the Go dial
    /// blocks for up to 30s, and the caller is the provider's message handler.
    func connectAsync(cols: Int, rows: Int) {
        lock.lock()
        lastCols = cols
        lastRows = rows
        generation &+= 1
        let gen = generation
        let pw = password
        let attempts = passwordAttempts
        lock.unlock()

        connectQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.sshClient.connect(self.host, port: self.port, user: self.user, password: pw)
                // The dial can take seconds, and a resize that lands in the
                // middle of it only reaches `lastCols`/`lastRows` — the PTY does
                // not exist yet to resize. Read them back here so the shell
                // starts at the grid the terminal actually has.
                self.lock.lock()
                let startCols = self.lastCols, startRows = self.lastRows
                self.lock.unlock()
                try self.sshClient.startSession(startCols, rows: startRows)
                self.lock.lock()
                let stale = gen != self.generation
                if !stale {
                    self.sessionStarted = true
                    // The password that got us here was accepted, so a later
                    // prompt in this session is a fresh ask, not a retry.
                    self.passwordAttempts = 0
                }
                self.lock.unlock()
            } catch {
                self.handleConnectFailure(error, generation: gen, priorAttempts: attempts)
            }
        }
    }

    private func handleConnectFailure(_ error: Error, generation gen: UInt64, priorAttempts: Int) {
        let message = (error as NSError).localizedDescription

        if message.contains(sshPasswordRequiredMarker) {
            // The marker on a retry means the password was wrong. A non-empty
            // message marks the retry case; the wording it turns into belongs
            // to the app, which has the localized strings.
            setState(.needsPassword, priorAttempts > 0 ? sshRejectedMarker : "", generation: gen)
            return
        }
        if let fingerprint = Self.hostKeyFingerprint(in: message) {
            setState(.needsHostKeyConfirm, fingerprint, generation: gen)
            return
        }
        setState(.error, message, generation: gen)
    }

    /// Pulls the SHA256 fingerprint out of the host-key marker, or returns nil
    /// when the error is not that marker. The Go side formats it as
    /// "netbird-ssh-hostkey-unknown:SHA256:...".
    private static func hostKeyFingerprint(in message: String) -> String? {
        guard let markerRange = message.range(of: sshHostKeyUnknownMarker),
              let colon = message.range(of: ":", range: markerRange.lowerBound..<message.endIndex)
        else { return nil }
        let fingerprint = message[colon.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return fingerprint.isEmpty ? nil : fingerprint
    }

    /// Retries with a password the user supplied after the session landed in
    /// `needsPassword`. Can be called repeatedly: a rejected password puts the
    /// session back into that state, so the user gets further attempts as with
    /// any ssh client.
    func retryWithPassword(_ password: String) {
        lock.lock()
        self.password = password
        passwordAttempts += 1
        let cols = lastCols, rows = lastRows
        lock.unlock()
        setState(.connecting, "")
        connectAsync(cols: cols, rows: rows)
    }

    /// Retries after the user confirmed the host-key fingerprint. The confirmed
    /// fingerprint is handed to the client so it trusts exactly that key and
    /// persists it; a key that changed since the prompt makes the retry fail.
    func retryWithHostKeyTrust(_ fingerprint: String) {
        sshClient.trustHostKey(fingerprint)
        lock.lock()
        let cols = lastCols, rows = lastRows
        lock.unlock()
        setState(.connecting, "")
        connectAsync(cols: cols, rows: rows)
    }

    /// Gives up on a session waiting for a password or a host key; otherwise it
    /// would be parked in that state with no way forward.
    func cancelPrompt() {
        setState(.closed, "cancelled")
    }

    /// Dials again, reusing this session so the app's scrollback survives. The
    /// password is kept: a server that wanted one before will want it again.
    func reconnect(cols: Int, rows: Int) {
        lock.lock()
        guard state.isReconnectable else { lock.unlock(); return }
        sessionStarted = false
        passwordAttempts = 0
        lock.unlock()

        // Close leaves the Go client's one-shot guard set; clearing it lets the
        // same client back another dial.
        sshClient.reset()
        setState(.connecting, "")
        connectAsync(cols: cols, rows: rows)
    }

    /// Ends the connection but keeps the session listed for a reconnect.
    func disconnect() {
        lock.lock()
        let alreadyDown = state.isReconnectable
        lock.unlock()
        if alreadyDown { return }

        try? sshClient.close()
        lock.lock()
        sessionStarted = false
        lock.unlock()
        setState(.closed, "disconnected")
    }

    /// Ends the connection for good; the manager drops the session afterwards.
    func close() {
        try? sshClient.close()
        lock.lock()
        let wasLive = !state.isReconnectable
        lock.unlock()
        if wasLive {
            setState(.closed, "closed by user")
        }
    }

    // MARK: - Terminal I/O

    func write(_ data: Data) -> String? {
        do {
            try sshClient.write(data)
            return nil
        } catch {
            return (error as NSError).localizedDescription
        }
    }

    func resize(cols: Int, rows: Int) -> String? {
        lock.lock()
        lastCols = cols
        lastRows = rows
        let started = sessionStarted
        lock.unlock()
        // Resizing before the PTY exists is not an error: the size is recorded
        // and the next dial requests it.
        guard started else { return nil }
        do {
            try sshClient.resize(cols, rows: rows)
            return nil
        } catch {
            return (error as NSError).localizedDescription
        }
    }

    /// Blocks the calling thread until output is available, the state changes,
    /// or `timeout` elapses, then returns whatever accumulated since the last
    /// poll together with the current state. Background queues only.
    func poll(timeout: TimeInterval) -> SSHReply {
        _ = dataAvailable.wait(timeout: .now() + timeout)
        // Drain extra signals that piled up while the buffer was being built,
        // so the next wait actually blocks.
        while dataAvailable.wait(timeout: .now()) == .success {}

        lock.lock()
        defer { lock.unlock() }

        var chunk = pendingData
        pendingData = Data()
        if pendingTruncated {
            chunk = Data("\r\n\u{1b}[33m[output truncated]\u{1b}[0m\r\n".utf8) + chunk
            pendingTruncated = false
        }

        return SSHReply(ok: true,
                        dataBase64: chunk.base64EncodedString(),
                        state: state,
                        message: stateMessage)
    }

    /// Current state without waiting, for replies that are not a poll.
    func snapshot() -> SSHReply {
        lock.lock()
        defer { lock.unlock() }
        return SSHReply(ok: true, state: state, message: stateMessage)
    }

    // MARK: - State

    private func setState(_ newState: SSHSessionState, _ message: String, generation gen: UInt64? = nil) {
        lock.lock()
        if let gen, gen != generation {
            // An abandoned attempt reporting in; the session has moved on.
            lock.unlock()
            return
        }
        state = newState
        stateMessage = message
        lock.unlock()
        // Wake any waiting poll so a state change reaches the app promptly
        // rather than after the poll's full timeout.
        dataAvailable.signal()
    }

    // MARK: - NetBirdSDKSSHTerminalListenerProtocol

    func onConnected() {
        setState(.connected, "")
    }

    func onData(_ data: Data?) {
        guard let data, !data.isEmpty else { return }
        lock.lock()
        pendingData.append(data)
        if pendingData.count > Self.maxPendingBytes {
            pendingData = Data(pendingData.suffix(Self.maxPendingBytes))
            pendingTruncated = true
        }
        lock.unlock()
        dataAvailable.signal()
    }

    func onClose(_ reason: String?) {
        lock.lock()
        sessionStarted = false
        lock.unlock()
        setState(.closed, reason ?? "")
    }

    func onError(_ message: String?) {
        lock.lock()
        sessionStarted = false
        lock.unlock()
        setState(.error, message ?? "")
    }
}

/// Owns every live SSH session for the lifetime of the extension process, keyed
/// by the opaque session id the app chose. A session stays here after it closes
/// so the app can redial it; only `close` drops it.
final class SSHSessionManager {
    private let lock = NSLock()
    private var sessions: [String: SSHSession] = [:]

    /// Creates the session and starts dialling. Returns immediately: progress
    /// is reported through `poll`, exactly as on Android, so the app can show a
    /// terminal that fills in rather than blocking on the dial.
    func open(command: SSHCommand, nbClient: NetBirdSDKClient) -> SSHReply {
        guard let host = command.host, !host.isEmpty,
              let user = command.user, !user.isEmpty,
              let port = command.port else {
            return .failure("incomplete SSH target")
        }
        // Reopening an id that is still live would leak the old connection.
        if let existing = session(for: command.sessionID) {
            existing.close()
            remove(command.sessionID)
        }
        guard let session = SSHSession(nbClient: nbClient, host: host, port: port, user: user) else {
            return .failure("failed to create SSH client")
        }
        if let configDir = command.configDir, let profileID = command.profileID,
           !configDir.isEmpty, !profileID.isEmpty {
            session.setKnownHostsStore(configDir: configDir, profileID: profileID)
        }

        lock.lock()
        sessions[command.sessionID] = session
        lock.unlock()

        session.connectAsync(cols: command.cols ?? 80, rows: command.rows ?? 24)
        return session.snapshot()
    }

    func poll(sessionID: String, timeout: TimeInterval) -> SSHReply {
        guard let session = session(for: sessionID) else {
            return SSHReply(ok: true, state: .closed, message: "session not found")
        }
        return session.poll(timeout: timeout)
    }

    func write(sessionID: String, data: Data) -> SSHReply {
        guard let session = session(for: sessionID) else { return .failure("session not found") }
        if let error = session.write(data) { return .failure(error) }
        return SSHReply(ok: true)
    }

    func resize(sessionID: String, cols: Int, rows: Int) -> SSHReply {
        guard let session = session(for: sessionID) else { return .failure("session not found") }
        if let error = session.resize(cols: cols, rows: rows) { return .failure(error) }
        return SSHReply(ok: true)
    }

    func retryWithPassword(sessionID: String, password: String) -> SSHReply {
        guard let session = session(for: sessionID) else { return .failure("session not found") }
        session.retryWithPassword(password)
        return session.snapshot()
    }

    func trustHostKey(sessionID: String, fingerprint: String) -> SSHReply {
        guard let session = session(for: sessionID) else { return .failure("session not found") }
        session.retryWithHostKeyTrust(fingerprint)
        return session.snapshot()
    }

    func cancelPrompt(sessionID: String) -> SSHReply {
        guard let session = session(for: sessionID) else { return .failure("session not found") }
        session.cancelPrompt()
        return session.snapshot()
    }

    func disconnect(sessionID: String) -> SSHReply {
        guard let session = session(for: sessionID) else { return .failure("session not found") }
        session.disconnect()
        return session.snapshot()
    }

    func reconnect(sessionID: String, command: SSHCommand, nbClient: NetBirdSDKClient) -> SSHReply {
        // A session the extension no longer knows — it was restored from the
        // profile's store, or the extension restarted — is simply opened afresh.
        guard let session = session(for: sessionID) else {
            return open(command: command, nbClient: nbClient)
        }
        session.reconnect(cols: command.cols ?? 80, rows: command.rows ?? 24)
        return session.snapshot()
    }

    func close(sessionID: String) -> SSHReply {
        guard let session = session(for: sessionID) else { return SSHReply(ok: true) }
        session.close()
        remove(sessionID)
        return SSHReply(ok: true, state: .closed, message: "closed by user")
    }

    /// Tears every session down. Called when the tunnel stops: an SSH session
    /// dials through it, so nothing here can survive its loss.
    func closeAll() {
        lock.lock()
        let all = Array(sessions.values)
        sessions.removeAll()
        lock.unlock()
        all.forEach { $0.close() }
    }

    private func session(for sessionID: String) -> SSHSession? {
        lock.lock()
        defer { lock.unlock() }
        return sessions[sessionID]
    }

    private func remove(_ sessionID: String) {
        lock.lock()
        sessions.removeValue(forKey: sessionID)
        lock.unlock()
    }
}
