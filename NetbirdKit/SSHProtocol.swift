//
//  SSHProtocol.swift
//  NetbirdKit
//
//  Wire format between the main app and the NetbirdNetworkExtension for SSH.
//  The live gomobile SSHClient only exists in the extension, next to the
//  tunnel-bound Client, so every session action the UI takes is one of these
//  commands sent over NETunnelProviderSession.sendProviderMessage.
//
//  JSON rather than a delimited string: a host, user name or close reason may
//  contain the separator, and a truncated field would dial the wrong target.
//

import Foundation

/// Lifecycle of one SSH session, mirroring the Android client's
/// `SshSession.State` so both platforms label and branch on the same set.
///
/// `needsPassword` and `needsHostKeyConfirm` are pauses, not failures: each
/// waits for the UI to answer with the matching command.
public enum SSHSessionState: String, Codable {
    case connecting
    case connected
    case needsPassword = "needs_password"
    case needsHostKeyConfirm = "needs_hostkey_confirm"
    case closed
    case error

    /// True while the session is finished but still reconnectable.
    public var isReconnectable: Bool {
        self == .closed || self == .error
    }
}

/// How a failed dial is reported back. The Go binding flattens errors to their
/// message, so a sentinel value would not survive the gomobile boundary; these
/// markers are the protocol instead. Two of the three outcomes are not failures
/// at all but pauses the UI can answer.
enum SSHConnectFailure: Equatable {
    /// The server wants a password. `rejected` is true when one was already
    /// tried and turned down, which is the difference between a first ask and
    /// a retry.
    case passwordRequired(rejected: Bool)
    /// A regular server presented a host key that is not yet trusted, with the
    /// SHA256 fingerprint to show for confirmation.
    case hostKeyUnknown(fingerprint: String)
    /// A genuine failure, carrying the message to print.
    case failed(message: String)

    /// Marker the Go binding puts in the error when a password would help.
    static let passwordRequiredMarker = "netbird-ssh-password-required"
    /// Marker the Go binding puts in the error, followed by ":" and the
    /// presented SHA256 fingerprint, when a regular server's host key is not
    /// yet trusted.
    static let hostKeyUnknownMarker = "netbird-ssh-hostkey-unknown"
    /// Marks a password prompt as following a rejection rather than a first ask.
    static let rejectedMarker = "rejected"

    /// Classifies a connect error. `priorAttempts` is how many passwords this
    /// session has already offered: the same marker means "tell me one" the
    /// first time and "that one was wrong" afterwards.
    static func classify(_ message: String, priorAttempts: Int) -> SSHConnectFailure {
        if message.contains(passwordRequiredMarker) {
            return .passwordRequired(rejected: priorAttempts > 0)
        }
        if let fingerprint = hostKeyFingerprint(in: message) {
            return .hostKeyUnknown(fingerprint: fingerprint)
        }
        return .failed(message: message)
    }

    /// Pulls the SHA256 fingerprint out of the host-key marker, or returns nil
    /// when the error is not that marker. The Go side formats it as
    /// "netbird-ssh-hostkey-unknown:SHA256:...".
    static func hostKeyFingerprint(in message: String) -> String? {
        guard let marker = message.range(of: hostKeyUnknownMarker),
              let colon = message.range(of: ":", range: marker.upperBound..<message.endIndex)
        else { return nil }
        let fingerprint = message[colon.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return fingerprint.isEmpty ? nil : fingerprint
    }

    /// The state and detail this outcome puts the session into.
    var resolution: (state: SSHSessionState, message: String) {
        switch self {
        case .passwordRequired(let rejected):
            return (.needsPassword, rejected ? Self.rejectedMarker : "")
        case .hostKeyUnknown(let fingerprint):
            return (.needsHostKeyConfirm, fingerprint)
        case .failed(let message):
            return (.error, message)
        }
    }
}

/// What the app asks the extension to do with a session.
public enum SSHCommandKind: String, Codable {
    /// Create the session and start dialling. Carries the target and the
    /// profile whose known-hosts store verifies regular servers.
    case open
    /// Long-poll for output and state changes.
    case poll
    case write
    case resize
    /// Answer a `needsPassword` pause and retry.
    case password
    /// Answer a `needsHostKeyConfirm` pause and retry with that key trusted.
    case trustHostKey
    /// Give up on a pause; the session ends.
    case cancelPrompt
    /// Hang up but keep the session, so it can be redialled.
    case disconnect
    /// Redial a closed or failed session.
    case reconnect
    /// Hang up and forget the session entirely.
    case close
}

public struct SSHCommand: Codable {
    public var kind: SSHCommandKind
    public var sessionID: String
    public var host: String?
    public var port: Int?
    public var user: String?
    public var cols: Int?
    public var rows: Int?
    /// NetBird config directory the per-profile preferences live under.
    public var configDir: String?
    /// Profile whose known-hosts store verifies regular servers. An overlay IP
    /// is a different host under a different profile, so a trusted key must
    /// never cross profiles.
    public var profileID: String?
    public var dataBase64: String?
    /// Password or host-key fingerprint, depending on `kind`.
    public var text: String?
    public var timeoutMs: Int?

    public init(kind: SSHCommandKind,
                sessionID: String,
                host: String? = nil,
                port: Int? = nil,
                user: String? = nil,
                cols: Int? = nil,
                rows: Int? = nil,
                configDir: String? = nil,
                profileID: String? = nil,
                dataBase64: String? = nil,
                text: String? = nil,
                timeoutMs: Int? = nil) {
        self.kind = kind
        self.sessionID = sessionID
        self.host = host
        self.port = port
        self.user = user
        self.cols = cols
        self.rows = rows
        self.configDir = configDir
        self.profileID = profileID
        self.dataBase64 = dataBase64
        self.text = text
        self.timeoutMs = timeoutMs
    }
}

public struct SSHReply: Codable {
    public var ok: Bool
    /// Set when the command itself could not be carried out, as opposed to the
    /// session reporting a failure through `state`.
    public var error: String?
    /// Output accumulated since the previous poll, base64-encoded.
    public var dataBase64: String?
    public var state: SSHSessionState?
    /// State detail: a close reason, an error text, the presented host-key
    /// fingerprint, or the rejected marker on a repeated password prompt.
    public var message: String?

    public init(ok: Bool,
                error: String? = nil,
                dataBase64: String? = nil,
                state: SSHSessionState? = nil,
                message: String? = nil) {
        self.ok = ok
        self.error = error
        self.dataBase64 = dataBase64
        self.state = state
        self.message = message
    }

    public static func failure(_ message: String) -> SSHReply {
        SSHReply(ok: false, error: message)
    }
}

/// Prefix that marks a provider message as an SSH command; the rest is the
/// base64-encoded JSON body.
public let sshMessagePrefix = "SSHv2:"

public enum SSHMessageCoder {
    public static func encode(_ command: SSHCommand) -> Data? {
        guard let body = try? JSONEncoder().encode(command) else { return nil }
        return (sshMessagePrefix + body.base64EncodedString()).data(using: .utf8)
    }

    public static func decodeCommand(_ payload: String) -> SSHCommand? {
        guard let body = Data(base64Encoded: payload) else { return nil }
        return try? JSONDecoder().decode(SSHCommand.self, from: body)
    }

    public static func encode(_ reply: SSHReply) -> Data? {
        try? JSONEncoder().encode(reply)
    }

    public static func decodeReply(_ data: Data?) -> SSHReply? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(SSHReply.self, from: data)
    }
}
