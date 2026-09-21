//
//  SSHIPC.swift
//  NetbirdKit
//
//  Drives an SSH session living in the NetbirdNetworkExtension process (the
//  only place the live, tunnel-bound NetBirdSDKClient exists) from the main
//  app via NETunnelProviderSession.sendProviderMessage, since the two run in
//  separate OS processes with no shared memory.
//
//  Every call is one `SSHCommand` and one `SSHReply`; see
//  `NetbirdKit/SSHProtocol.swift` for the shapes.
//

import Foundation
import NetworkExtension

extension NetworkExtensionAdapter {

    /// Creates the session in the extension and starts dialling. Returns as
    /// soon as the dial is under way — progress arrives through `sshPoll` — so
    /// the terminal can show the attempt rather than a frozen screen.
    ///
    /// One connect path for every target, peer or not: the SDK detects the
    /// server type and picks the auth method, so the JWT is only ever offered
    /// to a verified NetBird SSH service and no password is asked for up front.
    ///
    /// `configDir` and `profileID` point the host-key checks at the active
    /// profile's known-hosts store; an overlay IP is a different host under a
    /// different profile, so a trusted key must not cross profiles.
    func sshOpen(sessionID: String,
                 host: String,
                 port: Int,
                 user: String,
                 cols: Int,
                 rows: Int,
                 configDir: String?,
                 profileID: String?,
                 completion: @escaping (SSHReply) -> Void) {
        send(SSHCommand(kind: .open,
                        sessionID: sessionID,
                        host: host,
                        port: port,
                        user: user,
                        cols: cols,
                        rows: rows,
                        configDir: configDir,
                        profileID: profileID),
             completion: completion)
    }

    /// Blocks the extension's SSH queue (not this call) until output arrives,
    /// the state changes, or `timeoutMs` elapses, then returns the chunk since
    /// the last poll together with the session's state. Callers loop on this to
    /// drive the terminal.
    func sshPoll(sessionID: String, timeoutMs: Int, completion: @escaping (SSHReply) -> Void) {
        send(SSHCommand(kind: .poll, sessionID: sessionID, timeoutMs: timeoutMs),
             completion: completion)
    }

    func sshWrite(sessionID: String, data: Data, completion: @escaping (SSHReply) -> Void = { _ in }) {
        send(SSHCommand(kind: .write, sessionID: sessionID, dataBase64: data.base64EncodedString()),
             completion: completion)
    }

    func sshResize(sessionID: String, cols: Int, rows: Int, completion: @escaping (SSHReply) -> Void = { _ in }) {
        send(SSHCommand(kind: .resize, sessionID: sessionID, cols: cols, rows: rows),
             completion: completion)
    }

    /// Answers a `needsPassword` pause. The password is only ever held in
    /// memory for the session that asked for it, on both sides of the IPC.
    func sshSendPassword(sessionID: String, password: String, completion: @escaping (SSHReply) -> Void = { _ in }) {
        send(SSHCommand(kind: .password, sessionID: sessionID, text: password), completion: completion)
    }

    /// Answers a `needsHostKeyConfirm` pause: the retry accepts exactly this
    /// fingerprint and persists it, so a key that changed between the prompt
    /// and the retry fails rather than being trusted.
    func sshTrustHostKey(sessionID: String, fingerprint: String, completion: @escaping (SSHReply) -> Void = { _ in }) {
        send(SSHCommand(kind: .trustHostKey, sessionID: sessionID, text: fingerprint), completion: completion)
    }

    func sshCancelPrompt(sessionID: String, completion: @escaping (SSHReply) -> Void = { _ in }) {
        send(SSHCommand(kind: .cancelPrompt, sessionID: sessionID), completion: completion)
    }

    /// Hangs up but keeps the session, so the list can offer a redial.
    func sshDisconnect(sessionID: String, completion: @escaping (SSHReply) -> Void = { _ in }) {
        send(SSHCommand(kind: .disconnect, sessionID: sessionID), completion: completion)
    }

    /// Redials a closed or failed session. A session the extension no longer
    /// knows — restored from the profile's store, or lost to an extension
    /// restart — is opened afresh, which is why the target travels along.
    func sshReconnect(sessionID: String,
                      host: String,
                      port: Int,
                      user: String,
                      cols: Int,
                      rows: Int,
                      configDir: String?,
                      profileID: String?,
                      completion: @escaping (SSHReply) -> Void) {
        send(SSHCommand(kind: .reconnect,
                        sessionID: sessionID,
                        host: host,
                        port: port,
                        user: user,
                        cols: cols,
                        rows: rows,
                        configDir: configDir,
                        profileID: profileID),
             completion: completion)
    }

    /// Hangs up and forgets the session in the extension.
    func sshClose(sessionID: String, completion: @escaping (SSHReply) -> Void = { _ in }) {
        send(SSHCommand(kind: .close, sessionID: sessionID), completion: completion)
    }

    // MARK: - Transport

    private func send(_ command: SSHCommand, completion: @escaping (SSHReply) -> Void) {
        guard let session = self.session else {
            completion(.failure("VPN session not available"))
            return
        }
        guard let messageData = SSHMessageCoder.encode(command) else {
            completion(.failure("failed to encode SSH command"))
            return
        }
        do {
            try session.sendProviderMessage(messageData) { response in
                guard let reply = SSHMessageCoder.decodeReply(response) else {
                    completion(.failure("no response from extension"))
                    return
                }
                completion(reply)
            }
        } catch {
            completion(.failure(error.localizedDescription))
        }
    }
}
