//
//  SSHSessionRegistry.swift
//  NetbirdKit
//
//  App-side registry of SSH sessions, the counterpart of the Android client's
//  `SshSessionManager`/`SshSession` pair. The live connections belong to the
//  network extension; what lives here is everything the UI needs — the target,
//  the state, the scrollback — plus the poll loop that keeps them current.
//
//  The scrollback is held here rather than in the extension on purpose: it is
//  the largest thing a session owns, and the extension runs under a memory
//  budget the tunnel itself has first claim on.
//

import Foundation
import Combine

/// Snapshot of one session for the list, stable enough for SwiftUI diffing.
struct SSHSessionInfo: Identifiable, Equatable {
    let id: String
    let host: String
    let port: Int
    let user: String
    let state: SSHSessionState
    let stateMessage: String
    /// False when there is no output worth reading before reconnecting.
    let hasScrollback: Bool
    /// 1-based position among sessions to the same target; 0 when alone.
    let ordinal: Int

    var target: String { "\(user)@\(host):\(port)" }

    /// Leading ordinal, like tmux: the target is long enough to get truncated
    /// on a narrow row, which would drop the very part that disambiguates.
    var label: String { ordinal > 0 ? "#\(ordinal)  \(target)" : target }
}

/// What a terminal view attaches to receive live output and state.
protocol SSHSessionListener: AnyObject {
    func sshSessionDidReplayScrollback(_ data: Data)
    func sshSessionDidReceive(_ data: Data)
    func sshSessionDidChangeState(_ state: SSHSessionState, message: String)
}

/// One session: its target, its state, its scrollback, and the poll loop that
/// pulls both from the extension.
@MainActor
final class SSHSessionHandle {

    /// Matches the Android client's ring buffer, so the same amount of history
    /// survives a detach on both platforms.
    private static let maxScrollback = 256 * 1024
    private static let pollTimeoutMs = 25_000

    let id: String
    private(set) var host: String
    private(set) var port: Int
    private(set) var user: String

    private(set) var state: SSHSessionState = .closed
    private(set) var stateMessage = ""
    /// Sticky, unlike the live state: a reconnect must not read as a first
    /// connect, which is what tells the terminal whether to clear itself.
    private(set) var hasEverConnected = false

    private var scrollback = Data()
    private(set) var isScrollbackTruncated = false

    private var listeners: [ObjectIdentifier: WeakListener] = [:]
    private var isPolling = false
    /// Bumped whenever the session is retargeted or redialled, so a poll reply
    /// belonging to the previous attempt is discarded.
    private var generation: UInt64 = 0

    private var lastCols = 80
    private var lastRows = 24

    private unowned let registry: SSHSessionRegistry

    private struct WeakListener {
        weak var value: SSHSessionListener?
    }

    init(id: String, host: String, port: Int, user: String, registry: SSHSessionRegistry) {
        self.id = id
        self.host = host
        self.port = port
        self.user = user
        self.registry = registry
    }

    var target: String { "\(user)@\(host):\(port)" }
    var hasScrollback: Bool { !scrollback.isEmpty }
    var isReconnectable: Bool { state.isReconnectable }
    var cols: Int { lastCols }
    var rows: Int { lastRows }

    // MARK: - Listeners

    /// Attaching replays the scrollback and then the current state, so a view
    /// that arrives late sees the same sequence as one that was there all along.
    func attach(_ listener: SSHSessionListener) {
        listeners[ObjectIdentifier(listener)] = WeakListener(value: listener)
        if !scrollback.isEmpty {
            listener.sshSessionDidReplayScrollback(scrollback)
        }
        listener.sshSessionDidChangeState(state, message: stateMessage)
    }

    func detach(_ listener: SSHSessionListener) {
        listeners.removeValue(forKey: ObjectIdentifier(listener))
    }

    private func notifyData(_ data: Data) {
        liveListeners().forEach { $0.sshSessionDidReceive(data) }
    }

    private func notifyState() {
        let state = self.state, message = self.stateMessage
        liveListeners().forEach { $0.sshSessionDidChangeState(state, message: message) }
    }

    private func liveListeners() -> [SSHSessionListener] {
        listeners = listeners.filter { $0.value.value != nil }
        return listeners.values.compactMap { $0.value }
    }


    /// Starts a new attempt: invalidates whatever is in flight and stops the
    /// poll loop that serves it. Stopping matters as much as the bump — the
    /// in-flight poll bails out on the generation check without clearing
    /// `isPolling`, and a stale flag would make the next `beginPolling` a
    /// no-op, leaving the terminal silent.
    @discardableResult
    private func beginAttempt() -> UInt64 {
        isPolling = false
        generation &+= 1
        return generation
    }

    // MARK: - Lifecycle

    /// Retargets a stored session in place. The details are final on a live
    /// connection, which belonged to the old target anyway, so the scrollback
    /// goes with them.
    func retarget(host: String, port: Int, user: String) {
        beginAttempt()
        self.host = host
        self.port = port
        self.user = user
        scrollback.removeAll()
        isScrollbackTruncated = false
        hasEverConnected = false
        setState(.closed, "")
    }

    func open(cols: Int, rows: Int) {
        lastCols = cols
        lastRows = rows
        let gen = beginAttempt()
        setState(.connecting, "")

        registry.adapter?.sshOpen(sessionID: id,
                                  host: host,
                                  port: port,
                                  user: user,
                                  cols: cols,
                                  rows: rows,
                                  configDir: registry.configDir,
                                  profileID: registry.activeProfileID) { [weak self] reply in
            Task { @MainActor in
                self?.handleCommandReply(reply, generation: gen, startPolling: true)
            }
        }
    }

    func reconnect(cols: Int, rows: Int) {
        lastCols = cols
        lastRows = rows
        let gen = beginAttempt()
        setState(.connecting, "")

        registry.adapter?.sshReconnect(sessionID: id,
                                       host: host,
                                       port: port,
                                       user: user,
                                       cols: cols,
                                       rows: rows,
                                       configDir: registry.configDir,
                                       profileID: registry.activeProfileID) { [weak self] reply in
            Task { @MainActor in
                self?.handleCommandReply(reply, generation: gen, startPolling: true)
            }
        }
    }

    func disconnect() {
        guard !isReconnectable else { return }
        registry.adapter?.sshDisconnect(sessionID: id) { [weak self] reply in
            Task { @MainActor in self?.handleCommandReply(reply, generation: nil, startPolling: false) }
        }
    }

    /// Ends the session in the extension. The entry itself is dropped by the
    /// registry, which owns the stored list.
    func closeRemote() {
        beginAttempt()
        registry.adapter?.sshClose(sessionID: id)
    }

    func retryWithPassword(_ password: String) {
        let gen = beginAttempt()
        setState(.connecting, "")
        registry.adapter?.sshSendPassword(sessionID: id, password: password) { [weak self] reply in
            Task { @MainActor in self?.handleCommandReply(reply, generation: gen, startPolling: true) }
        }
    }

    func retryWithHostKeyTrust(_ fingerprint: String) {
        let gen = beginAttempt()
        setState(.connecting, "")
        registry.adapter?.sshTrustHostKey(sessionID: id, fingerprint: fingerprint) { [weak self] reply in
            Task { @MainActor in self?.handleCommandReply(reply, generation: gen, startPolling: true) }
        }
    }

    /// Gives up on a session waiting for a password or a host key; otherwise it
    /// would be parked in that state with no way forward.
    func cancelPrompt() {
        beginAttempt()
        registry.adapter?.sshCancelPrompt(sessionID: id) { [weak self] reply in
            Task { @MainActor in self?.handleCommandReply(reply, generation: nil, startPolling: false) }
        }
        setState(.closed, "cancelled")
    }

    // MARK: - Terminal I/O

    func write(_ data: Data) {
        guard !data.isEmpty else { return }
        registry.adapter?.sshWrite(sessionID: id, data: data)
    }

    func resize(cols: Int, rows: Int) {
        lastCols = cols
        lastRows = rows
        registry.adapter?.sshResize(sessionID: id, cols: cols, rows: rows)
    }

    // MARK: - Polling

    private func handleCommandReply(_ reply: SSHReply, generation gen: UInt64?, startPolling: Bool) {
        if let gen, gen != generation { return }
        guard reply.ok else {
            setState(.error, reply.error ?? "")
            return
        }
        if let state = reply.state {
            setState(state, reply.message ?? "")
        }
        if startPolling { beginPolling() }
    }

    private func beginPolling() {
        guard !isPolling else { return }
        isPolling = true
        pollOnce(generation: generation)
    }

    private func pollOnce(generation gen: UInt64) {
        guard isPolling, gen == generation else { return }
        guard let adapter = registry.adapter else {
            isPolling = false
            return
        }
        adapter.sshPoll(sessionID: id, timeoutMs: Self.pollTimeoutMs) { [weak self] reply in
            Task { @MainActor in
                guard let self, self.isPolling, gen == self.generation else { return }

                guard reply.ok else {
                    // A transport failure is not the session failing: the
                    // tunnel session object can be momentarily unavailable
                    // after the app returns to the foreground. Back off and
                    // let the next attempt settle it.
                    self.isPolling = false
                    if !self.state.isReconnectable {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        if gen == self.generation, !self.state.isReconnectable {
                            self.beginPolling()
                        }
                    }
                    return
                }

                if let base64 = reply.dataBase64,
                   let data = Data(base64Encoded: base64), !data.isEmpty {
                    self.append(data)
                    self.notifyData(data)
                }
                if let state = reply.state {
                    self.setState(state, reply.message ?? "")
                    if state.isReconnectable {
                        self.isPolling = false
                        return
                    }
                }
                self.pollOnce(generation: gen)
            }
        }
    }

    // MARK: - State and buffer

    private func setState(_ newState: SSHSessionState, _ message: String) {
        let changed = newState != state || message != stateMessage
        state = newState
        stateMessage = message
        if newState == .connected { hasEverConnected = true }
        if changed {
            notifyState()
            registry.sessionDidChange()
        }
    }

    private func append(_ data: Data) {
        scrollback.append(data)
        if scrollback.count > Self.maxScrollback {
            scrollback = Data(scrollback.suffix(Self.maxScrollback))
            isScrollbackTruncated = true
        }
    }
}

/// Application-scoped registry of SSH sessions, outliving any single view.
/// Connection details are persisted per profile, so the list survives a
/// restart; the connections themselves cannot, and come back closed for a
/// reconnect.
@MainActor
final class SSHSessionRegistry: ObservableObject {

    static let shared = SSHSessionRegistry()

    /// Session snapshots for the UI, in creation order.
    @Published private(set) var sessions: [SSHSessionInfo] = []

    private(set) var handles: [SSHSessionHandle] = []
    private(set) var activeProfileID: String?

    /// Set while the app is attached to the tunnel session, cleared when it
    /// goes. Without it no command can reach the extension.
    weak var adapter: NetworkExtensionAdapter?

    var configDir: String { SSHSessionStore.configDir() }

    /// Sessions that are dialled or dialling, for the tab badge: a stored entry
    /// waiting to be redialled is not something to chase.
    var liveSessionCount: Int {
        sessions.filter { !$0.state.isReconnectable }.count
    }

    private init() {}

    func configure(adapter: NetworkExtensionAdapter) {
        self.adapter = adapter
    }

    /// Reports whether a connect attempt can get anywhere. An SSH session dials
    /// through the tunnel, so without it every attempt fails, and the caller
    /// can say so before opening a terminal that cannot work.
    var canConnect: Bool {
        adapter?.session?.status == .connected
    }

    // MARK: - Profile

    /// Points the list at a profile, loading its stored sessions. Switching
    /// closes whatever is live: the tunnel goes down with the old profile, and
    /// an overlay IP means a different host under the new one. A deleted
    /// profile needs no cleanup here: its stored list lives in the Go profile
    /// manager's preferences, which are deleted together with the profile.
    func setProfile(_ profileID: String?) {
        if let profileID, profileID == activeProfileID { return }
        closeAllInternal()
        activeProfileID = profileID

        if let profileID {
            for entry in SSHSessionStore.load(profileID: profileID) {
                handles.append(SSHSessionHandle(id: entry.id,
                                                host: entry.host,
                                                port: entry.port,
                                                user: entry.user,
                                                registry: self))
            }
        }
        publish()
    }

    // MARK: - Session list

    func handle(id: String) -> SSHSessionHandle? {
        handles.first { $0.id == id }
    }

    /// Adds a session and starts dialling it.
    @discardableResult
    func create(host: String, port: Int, user: String, cols: Int = 80, rows: Int = 24) -> SSHSessionHandle {
        let handle = SSHSessionHandle(id: UUID().uuidString,
                                      host: host,
                                      port: port,
                                      user: user,
                                      registry: self)
        handles.append(handle)
        persist()
        publish()
        handle.open(cols: cols, rows: rows)
        return handle
    }

    /// Opens a second session to the same target, connecting it right away.
    /// No credential is carried over: a password lives only in the session that
    /// was asked for it, so a server wanting one prompts again.
    @discardableResult
    func duplicate(id: String) -> SSHSessionHandle? {
        guard let source = handle(id: id), canConnect else { return nil }
        return create(host: source.host,
                      port: source.port,
                      user: source.user,
                      cols: source.cols,
                      rows: source.rows)
    }

    /// Changes where a stored session points. A live connection belongs to the
    /// old target, so it is dropped and the entry keeps its place in the list
    /// rather than being appended anew.
    ///
    /// Left disconnected on purpose: reconnecting here would dial before the
    /// user has seen whether the new details are right, and the list already
    /// offers a reconnect.
    @discardableResult
    func edit(id: String, host: String, port: Int, user: String) -> Bool {
        guard let handle = handle(id: id) else { return false }
        handle.closeRemote()
        handle.retarget(host: host, port: port, user: user)
        persist()
        publish()
        return true
    }

    /// Hangs up but keeps the entry, so the list can offer a redial.
    func disconnect(id: String) {
        handle(id: id)?.disconnect()
    }

    /// Redials a finished session.
    /// - Returns: false when the tunnel is down, so nothing could be dialled.
    @discardableResult
    func reconnect(id: String, cols: Int? = nil, rows: Int? = nil) -> Bool {
        guard let handle = handle(id: id), canConnect else { return false }
        handle.reconnect(cols: cols ?? handle.cols, rows: rows ?? handle.rows)
        return true
    }

    /// Removes the session for good, and with it the host's trusted key once no
    /// other session targets that host.
    func close(id: String) {
        guard let index = handles.firstIndex(where: { $0.id == id }) else { return }
        let handle = handles.remove(at: index)
        handle.closeRemote()
        forgetHostKeyIfUnused(host: handle.host, port: handle.port)
        persist()
        publish()
    }

    func closeAll() {
        closeAllInternal()
        persist()
        publish()
    }

    /// Tears the sessions down without persisting: callers decide what to store.
    private func closeAllInternal() {
        handles.forEach { $0.closeRemote() }
        handles.removeAll()
    }

    /// Drops the host's trusted key once no session targets it anymore, so a
    /// deleted host does not leave a trusted key behind. A host still used by
    /// another session keeps its key, so that session is not re-prompted.
    private func forgetHostKeyIfUnused(host: String, port: Int) {
        guard let profileID = activeProfileID else { return }
        if handles.contains(where: { $0.host == host && $0.port == port }) { return }
        SSHSessionStore.removeKnownHost(profileID: profileID, host: host, port: port)
    }

    // MARK: - Publishing

    /// Called by a handle whose state moved; a state change alters nothing that
    /// is stored, so it only refreshes the list.
    func sessionDidChange() {
        publish()
    }

    /// Numbers the sessions sharing a target, so parallel ones to the same host
    /// can be told apart. A target with only one session gets no number, since
    /// there is nothing to distinguish it from.
    private func publish() {
        var totals: [String: Int] = [:]
        for handle in handles {
            totals[handle.target, default: 0] += 1
        }
        var seen: [String: Int] = [:]
        sessions = handles.map { handle in
            var ordinal = 0
            if totals[handle.target, default: 0] > 1 {
                ordinal = seen[handle.target, default: 0] + 1
                seen[handle.target] = ordinal
            }
            return SSHSessionInfo(id: handle.id,
                                  host: handle.host,
                                  port: handle.port,
                                  user: handle.user,
                                  state: handle.state,
                                  stateMessage: handle.stateMessage,
                                  hasScrollback: handle.hasScrollback,
                                  ordinal: ordinal)
        }
    }

    /// Called on add/remove/edit only; a state change alters nothing stored.
    private func persist() {
        guard let profileID = activeProfileID else { return }
        SSHSessionStore.save(profileID: profileID,
                             sessions: handles.map {
                                 SSHStoredSession(id: $0.id, host: $0.host, port: $0.port, user: $0.user)
                             })
    }
}
