//
//  SSHActiveSessionStore.swift
//  NetBird
//

import Foundation

/// Tracks all live SSH sessions for the current app session.
/// Sessions remain here (and keep their connection) even when the terminal view is dismissed,
/// so the user can return to an ongoing session from ActiveSessionsView.
@MainActor
final class SSHActiveSessionStore: ObservableObject {
    @Published private(set) var sessions: [SSHSessionViewModel] = []

    func add(_ session: SSHSessionViewModel) {
        sessions.append(session)
    }

    func remove(id: String) {
        if let idx = sessions.firstIndex(where: { $0.sessionID == id }) {
            sessions[idx].stop()
            sessions.remove(at: idx)
        }
    }
}
