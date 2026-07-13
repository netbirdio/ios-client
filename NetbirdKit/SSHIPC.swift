//
//  SSHIPC.swift
//  NetbirdKit
//
//  Drives an SSH session living in the NetbirdNetworkExtension process (the
//  only place the live, tunnel-bound NetBirdSDKClient exists) from the main
//  app via NETunnelProviderSession.sendProviderMessage, since the two run in
//  separate OS processes with no shared memory.
//

import Foundation
import NetworkExtension

extension NetworkExtensionAdapter {

    /// For NetBird peers with SSH enabled in the dashboard — uses JWT auth, no detection, no password.
    func sshConnectNetBirdPeer(sessionID: String, host: String, port: Int, user: String, cols: Int, rows: Int, completion: @escaping (String?) -> Void) {
        guard let session = self.session else {
            completion("VPN session not available")
            return
        }
        let message = "SSHConnectNetBird:\(sessionID)|\(host)|\(port)|\(user)|\(cols)|\(rows)"
        sendSimpleMessage(message, session: session, completion: completion)
    }

    func sshConnect(sessionID: String, host: String, port: Int, user: String, password: String, cols: Int, rows: Int, completion: @escaping (String?) -> Void) {
        guard let session = self.session else {
            completion("VPN session not available")
            return
        }
        let passwordBase64 = Data(password.utf8).base64EncodedString()
        let message = "SSHConnect:\(sessionID)|\(host)|\(port)|\(user)|\(passwordBase64)|\(cols)|\(rows)"
        sendSimpleMessage(message, session: session, completion: completion)
    }

    func sshWrite(sessionID: String, data: Data, completion: @escaping (String?) -> Void) {
        guard let session = self.session else {
            completion("VPN session not available")
            return
        }
        let message = "SSHWrite:\(sessionID)|\(data.base64EncodedString())"
        sendSimpleMessage(message, session: session, completion: completion)
    }

    func sshResize(sessionID: String, cols: Int, rows: Int, completion: @escaping (String?) -> Void) {
        guard let session = self.session else {
            completion("VPN session not available")
            return
        }
        let message = "SSHResize:\(sessionID)|\(cols)|\(rows)"
        sendSimpleMessage(message, session: session, completion: completion)
    }

    func sshClose(sessionID: String) {
        guard let session = self.session, let messageData = "SSHClose:\(sessionID)".data(using: .utf8) else { return }
        try? session.sendProviderMessage(messageData) { _ in }
    }

    /// Blocks the extension's SSH queue (not this call) until output arrives,
    /// the session ends, or `timeoutMs` elapses, then returns the chunk since
    /// the last poll. Callers should call this in a loop to drive the terminal.
    func sshPoll(sessionID: String, timeoutMs: Int, completion: @escaping (SSHPollResult) -> Void) {
        guard let session = self.session else {
            completion(SSHPollResult(dataBase64: "", status: "closed", reason: "VPN session not available"))
            return
        }
        let message = "SSHPoll:\(sessionID)|\(timeoutMs)"
        guard let messageData = message.data(using: .utf8) else {
            completion(SSHPollResult(dataBase64: "", status: "closed", reason: "failed to encode message"))
            return
        }
        do {
            try session.sendProviderMessage(messageData) { [weak self] response in
                guard let response, let result = try? self?.decoder.decode(SSHPollResult.self, from: response) else {
                    completion(SSHPollResult(dataBase64: "", status: "closed", reason: "no response from extension"))
                    return
                }
                completion(result)
            }
        } catch {
            completion(SSHPollResult(dataBase64: "", status: "closed", reason: error.localizedDescription))
        }
    }

    private func sendSimpleMessage(_ message: String, session: NETunnelProviderSession, completion: @escaping (String?) -> Void) {
        guard let messageData = message.data(using: .utf8) else {
            completion("failed to encode message")
            return
        }
        do {
            try session.sendProviderMessage(messageData) { response in
                guard let response, let text = String(data: response, encoding: .utf8) else {
                    completion("no response from extension")
                    return
                }
                if text.hasPrefix("error:") {
                    completion(String(text.dropFirst("error:".count)))
                } else {
                    completion(nil)
                }
            }
        } catch {
            completion(error.localizedDescription)
        }
    }
}
