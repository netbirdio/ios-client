//
//  SSHSessionStore.swift
//  NetbirdKit
//

import Foundation
import Combine

final class SSHSessionStore: ObservableObject {
    @Published private(set) var sessions: [SavedSSHSession] = []

    private let key = "io.netbird.ssh.savedSessions"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() { load() }

    func add(_ session: SavedSSHSession) {
        sessions.append(session)
        persist()
    }

    func update(_ session: SavedSSHSession) {
        guard let idx = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions[idx] = session
        persist()
    }

    func delete(id: String) {
        sessions.removeAll { $0.id == id }
        SSHKeychainStore.delete(for: id)
        persist()
    }

    private func load() {
        guard let data = Preferences.sharedUserDefaults()?.data(forKey: key),
              let loaded = try? decoder.decode([SavedSSHSession].self, from: data) else { return }
        sessions = loaded
    }

    private func persist() {
        guard let data = try? encoder.encode(sessions) else { return }
        Preferences.sharedUserDefaults()?.set(data, forKey: key)
    }
}
