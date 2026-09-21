//
//  SSHSessionStore.swift
//  NetbirdKit
//
//  Persists the connection details of SSH sessions so the list survives a
//  restart. A live connection cannot outlive the extension process, so restored
//  entries come back closed and are reconnected on demand.
//
//  Stored per profile in the Go profile manager's preferences, the same store
//  and the same `ssh-sessions` namespace the Android client uses: an overlay IP
//  means a different host under a different profile, so one list must not leak
//  into another, and deleting a profile deletes its list with it.
//
//  Passwords are never written here: one is only ever held in memory for the
//  session that asked for it, and a restored entry prompts again.
//

import Foundation

#if os(iOS)
import NetBirdSDK
#endif

/// A stored session, without any credential.
struct SSHStoredSession: Equatable {
    let id: String
    let host: String
    let port: Int
    let user: String
}

enum SSHSessionStore {

    /// The login name last connected with, or an empty string on a fresh
    /// install. Not per profile: the login name belongs to whoever holds the
    /// phone, and the same account is typically used whichever profile is
    /// active.
    private static let lastUserKey = "io.netbird.ssh.lastUser"

    static var lastUser: String {
        get { Preferences.sharedUserDefaults()?.string(forKey: lastUserKey) ?? "" }
        set {
            guard !newValue.isEmpty else { return }
            Preferences.sharedUserDefaults()?.set(newValue, forKey: lastUserKey)
        }
    }

    /// The NetBird config directory the per-profile preferences live under; the
    /// session list and the known-hosts entries are both stored there by the Go
    /// profile manager, keyed by profile ID.
    static func configDir() -> String {
        ProfileManager.configDir()
    }

    static func load(profileID: String) -> [SSHStoredSession] {
#if os(iOS)
        guard !profileID.isEmpty else { return [] }
        var openError: NSError?
        guard let store = NetBirdSDKNewSSHSessionStore(configDir(), profileID, &openError) else {
            // A corrupt store is not worth failing over; start clean instead.
            AppLogger.shared.log("SSHSessionStore: could not open the session store: \(openError?.localizedDescription ?? "unknown error")")
            return []
        }
        do {
            let array = try store.load()
            var entries: [SSHStoredSession] = []
            for i in 0..<array.length() {
                guard let e = array.get(i), !e.id_.isEmpty, !e.host.isEmpty else { continue }
                entries.append(SSHStoredSession(id: e.id_, host: e.host, port: e.port, user: e.user))
            }
            return entries
        } catch {
            AppLogger.shared.log("SSHSessionStore: could not load stored SSH sessions: \(error.localizedDescription)")
            return []
        }
#else
        return []
#endif
    }

    static func save(profileID: String, sessions: [SSHStoredSession]) {
#if os(iOS)
        guard !profileID.isEmpty else { return }
        guard let array = NetBirdSDKNewSSHSessionArray() else { return }
        for session in sessions {
            array.add(session.id, host: session.host, port: session.port, user: session.user)
        }
        var openError: NSError?
        guard let store = NetBirdSDKNewSSHSessionStore(configDir(), profileID, &openError) else {
            AppLogger.shared.log("SSHSessionStore: could not open the session store: \(openError?.localizedDescription ?? "unknown error")")
            return
        }
        do {
            try store.save(array)
        } catch {
            AppLogger.shared.log("SSHSessionStore: could not persist SSH sessions: \(error.localizedDescription)")
        }
#endif
    }

    /// Drops the host's trusted key once no session targets it anymore, so a
    /// deleted host does not leave a trusted key behind. Callers check first
    /// that no other session uses the host, so a shared host stays trusted.
    /// A missing entry is not an error: the goal state is "absent".
    static func removeKnownHost(profileID: String, host: String, port: Int) {
#if os(iOS)
        guard !profileID.isEmpty else { return }
        var error: NSError?
        if !NetBirdSDKRemoveKnownHost(configDir(), profileID, host, port, &error), let error {
            AppLogger.shared.log("SSHSessionStore: could not remove host key for \(host):\(port): \(error.localizedDescription)")
        }
#endif
    }
}
