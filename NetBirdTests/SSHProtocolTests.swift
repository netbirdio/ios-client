//
//  SSHProtocolTests.swift
//  NetBirdTests
//
//  Covers the parts of the SSH feature that hold without a tunnel: the wire
//  format between the app and the network extension, the classification of a
//  dial failure into a pause or a real error, and the numbering that tells
//  parallel sessions to one host apart.
//
//  Everything else — the dial itself, the four auth paths, the known-hosts
//  store — needs a live extension and is covered by the manual checklist.
//

import XCTest
@testable import NetBird

final class SSHProtocolTests: XCTestCase {

    // MARK: - Wire format

    /// The delimited format this replaced could not carry a field containing
    /// the separator; the truncated host would then dial somewhere else.
    func testCommandSurvivesFieldsContainingTheOldSeparator() throws {
        let command = SSHCommand(kind: .open,
                                 sessionID: "id|1",
                                 host: "host|with|pipes",
                                 port: 2222,
                                 user: "us|er",
                                 cols: 120,
                                 rows: 40,
                                 configDir: "/tmp/dir|name",
                                 profileID: "profile|id")

        let encoded = try XCTUnwrap(SSHMessageCoder.encode(command))
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertTrue(text.hasPrefix(sshMessagePrefix))

        let payload = String(text.dropFirst(sshMessagePrefix.count))
        let decoded = try XCTUnwrap(SSHMessageCoder.decodeCommand(payload))

        XCTAssertEqual(decoded.kind, .open)
        XCTAssertEqual(decoded.sessionID, "id|1")
        XCTAssertEqual(decoded.host, "host|with|pipes")
        XCTAssertEqual(decoded.port, 2222)
        XCTAssertEqual(decoded.user, "us|er")
        XCTAssertEqual(decoded.cols, 120)
        XCTAssertEqual(decoded.rows, 40)
        XCTAssertEqual(decoded.configDir, "/tmp/dir|name")
        XCTAssertEqual(decoded.profileID, "profile|id")
    }

    /// Terminal output is arbitrary bytes, including invalid UTF-8 from a
    /// binary dump; it has to arrive byte for byte.
    func testReplyCarriesArbitraryBytesUnchanged() throws {
        let payload = Data([0x00, 0xff, 0x1b, 0x5b, 0x41, 0xc3, 0x28, 0x0a])
        let reply = SSHReply(ok: true,
                             dataBase64: payload.base64EncodedString(),
                             state: .connected,
                             message: "")

        let encoded = try XCTUnwrap(SSHMessageCoder.encode(reply))
        let decoded = try XCTUnwrap(SSHMessageCoder.decodeReply(encoded))

        XCTAssertTrue(decoded.ok)
        XCTAssertEqual(decoded.state, .connected)
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(decoded.dataBase64)), payload)
    }

    /// A close reason comes from the server and routinely contains newlines and
    /// colons; it must not be truncated or split.
    func testReplyKeepsMultilineCloseReason() throws {
        let reason = "Session closed:\nremote host closed the connection\r\nat 10:42:01"
        let encoded = try XCTUnwrap(SSHMessageCoder.encode(SSHReply(ok: true, state: .closed, message: reason)))
        let decoded = try XCTUnwrap(SSHMessageCoder.decodeReply(encoded))
        XCTAssertEqual(decoded.message, reason)
    }

    func testGarbageIsRejectedRatherThanMisread() {
        XCTAssertNil(SSHMessageCoder.decodeCommand("not base64 at all !!!"))
        XCTAssertNil(SSHMessageCoder.decodeCommand(Data("{\"nope\":1}".utf8).base64EncodedString()))
        XCTAssertNil(SSHMessageCoder.decodeReply(Data("garbage".utf8)))
        XCTAssertNil(SSHMessageCoder.decodeReply(nil))
    }

    /// The raw values travel over the wire and are also what the Android client
    /// names its states, so renaming a case silently breaks both.
    func testStateWireNamesAreStable() {
        XCTAssertEqual(SSHSessionState.connecting.rawValue, "connecting")
        XCTAssertEqual(SSHSessionState.connected.rawValue, "connected")
        XCTAssertEqual(SSHSessionState.needsPassword.rawValue, "needs_password")
        XCTAssertEqual(SSHSessionState.needsHostKeyConfirm.rawValue, "needs_hostkey_confirm")
        XCTAssertEqual(SSHSessionState.closed.rawValue, "closed")
        XCTAssertEqual(SSHSessionState.error.rawValue, "error")
    }

    /// Only a finished session may be redialled; a pause is answered instead.
    func testOnlyFinishedStatesAreReconnectable() {
        XCTAssertTrue(SSHSessionState.closed.isReconnectable)
        XCTAssertTrue(SSHSessionState.error.isReconnectable)
        XCTAssertFalse(SSHSessionState.connecting.isReconnectable)
        XCTAssertFalse(SSHSessionState.connected.isReconnectable)
        XCTAssertFalse(SSHSessionState.needsPassword.isReconnectable)
        XCTAssertFalse(SSHSessionState.needsHostKeyConfirm.isReconnectable)
    }

    // MARK: - Dial failure classification

    /// The first password marker is a request; the same marker after an attempt
    /// means the password was wrong, which is what the prompt says differently.
    func testPasswordMarkerTellsFirstAskFromRejection() {
        let message = "ssh: handshake failed: netbird-ssh-password-required"

        XCTAssertEqual(SSHConnectFailure.classify(message, priorAttempts: 0),
                       .passwordRequired(rejected: false))
        XCTAssertEqual(SSHConnectFailure.classify(message, priorAttempts: 1),
                       .passwordRequired(rejected: true))

        XCTAssertEqual(SSHConnectFailure.classify(message, priorAttempts: 0).resolution.state, .needsPassword)
        XCTAssertEqual(SSHConnectFailure.classify(message, priorAttempts: 0).resolution.message, "")
        XCTAssertEqual(SSHConnectFailure.classify(message, priorAttempts: 2).resolution.message,
                       SSHConnectFailure.rejectedMarker)
    }

    /// The fingerprint is what the user compares out of band, so every colon
    /// after the marker belongs to it.
    func testHostKeyMarkerYieldsTheWholeFingerprint() {
        let fingerprint = "SHA256:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU="
        let outcome = SSHConnectFailure.classify("netbird-ssh-hostkey-unknown:\(fingerprint)",
                                                 priorAttempts: 0)
        XCTAssertEqual(outcome, .hostKeyUnknown(fingerprint: fingerprint))
        XCTAssertEqual(outcome.resolution.state, .needsHostKeyConfirm)
        XCTAssertEqual(outcome.resolution.message, fingerprint)
    }

    /// A marker with nothing after it cannot be confirmed against anything, so
    /// it must surface as an error rather than an empty prompt.
    func testHostKeyMarkerWithoutAFingerprintIsAnError() {
        XCTAssertEqual(SSHConnectFailure.classify("netbird-ssh-hostkey-unknown:", priorAttempts: 0),
                       .failed(message: "netbird-ssh-hostkey-unknown:"))
        XCTAssertNil(SSHConnectFailure.hostKeyFingerprint(in: "netbird-ssh-hostkey-unknown"))
    }

    /// A dial that timed out is not a pause: prompting for a password would
    /// hide the real reason behind a dialog that cannot help.
    func testOrdinaryFailuresStayFailures() {
        let outcome = SSHConnectFailure.classify("dial 100.64.0.5:22: i/o timeout", priorAttempts: 3)
        XCTAssertEqual(outcome, .failed(message: "dial 100.64.0.5:22: i/o timeout"))
        XCTAssertEqual(outcome.resolution.state, .error)
    }

    // MARK: - Session numbering

    /// A lone session gets no number: there is nothing to distinguish it from.
    func testSingleSessionPerTargetIsNotNumbered() {
        let infos = SSHSessionInfo.numbered([
            draft(id: "a", host: "100.64.0.1", user: "root"),
            draft(id: "b", host: "100.64.0.2", user: "root"),
        ])
        XCTAssertEqual(infos.map(\.ordinal), [0, 0])
        XCTAssertEqual(infos[0].label, "root@100.64.0.1:22")
    }

    /// Parallel sessions to one target are numbered in list order, and the
    /// ordinal leads the label so a narrow row cannot truncate it away.
    func testParallelSessionsToOneTargetAreNumbered() {
        let infos = SSHSessionInfo.numbered([
            draft(id: "a", host: "100.64.0.1", user: "root"),
            draft(id: "b", host: "100.64.0.2", user: "root"),
            draft(id: "c", host: "100.64.0.1", user: "root"),
            draft(id: "d", host: "100.64.0.1", user: "root"),
        ])
        XCTAssertEqual(infos.map(\.ordinal), [1, 0, 2, 3])
        XCTAssertEqual(infos[0].label, "#1  root@100.64.0.1:22")
        XCTAssertEqual(infos[1].label, "root@100.64.0.2:22")
        XCTAssertEqual(infos[3].label, "#3  root@100.64.0.1:22")
    }

    /// The target includes the user and the port, so these are three different
    /// targets rather than one with three sessions.
    func testUserAndPortArePartOfTheTarget() {
        let infos = SSHSessionInfo.numbered([
            draft(id: "a", host: "100.64.0.1", port: 22, user: "root"),
            draft(id: "b", host: "100.64.0.1", port: 2222, user: "root"),
            draft(id: "c", host: "100.64.0.1", port: 22, user: "admin"),
        ])
        XCTAssertEqual(infos.map(\.ordinal), [0, 0, 0])
    }

    private func draft(id: String,
                       host: String,
                       port: Int = 22,
                       user: String,
                       state: SSHSessionState = .closed) -> SSHSessionInfo.Draft {
        SSHSessionInfo.Draft(id: id,
                             host: host,
                             port: port,
                             user: user,
                             state: state,
                             stateMessage: "",
                             hasScrollback: false)
    }
}
