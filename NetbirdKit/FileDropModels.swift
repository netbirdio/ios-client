//
//  FileDropModels.swift
//  NetBird
//
//  Shared file drop types passed between the app and the network extension.
//  The integer raw values mirror the Go filedrop package constants exported
//  through NetBirdSDK (mode, state, failure reason).
//

import Foundation
import NetBirdSDK

/// Base receiving policy, mirrors filedrop.Mode in netbird-core.
enum FileDropMode: Int, CaseIterable, Codable {
    case off = 0
    case ask = 1
    case autoAccept = 2
}

/// Transfer lifecycle state, mirrors filedrop.State in netbird-core.
enum FileDropState: Int, Codable {
    case pending = 0
    case transferring = 1
    case completed = 2
    case declined = 3
    case expired = 4
    case cancelled = 5
    case failed = 6
}

/// Failure detail, mirrors filedrop.FailureReason in netbird-core.
enum FileDropReason: Int, Codable {
    case none = 0
    case unreachable = 1
}

/// Snapshot of one transfer, encoded by the extension for the app.
struct FileDropTransferInfo: Codable, Identifiable, Equatable {
    var id: String
    var outgoing: Bool
    var peerKey: String
    var peerName: String
    var state: Int
    var transferred: Int64
    var totalSize: Int64
    var createdAtMillis: Int64
    var updatedAtMillis: Int64
    var isText: Bool
    var text: String
    var error: String
    var reason: Int
    var fileNames: [String]
    var deliveredPaths: [String]

    var transferState: FileDropState { FileDropState(rawValue: state) ?? .failed }
    var isUnreachable: Bool { FileDropReason(rawValue: reason) == .unreachable }
    var isTerminal: Bool {
        switch transferState {
        case .pending, .transferring: return false
        default: return true
        }
    }
    /// An incoming offer still waiting for the user's answer.
    var isAnswerable: Bool { !outgoing && transferState == .pending }
    var createdAt: Date? {
        createdAtMillis > 0 ? Date(timeIntervalSince1970: TimeInterval(createdAtMillis) / 1000) : nil
    }
}

extension FileDropTransferInfo {
    /// Snapshot of the gomobile transfer object, taken by whichever process
    /// holds the SDK handle.
    init(sdk t: NetBirdSDKFileDropTransfer) {
        var fileNames: [String] = []
        var text = ""
        for i in 0..<t.fileCount() {
            guard let file = t.getFile(i) else { continue }
            if file.isText {
                text = file.text
            } else {
                fileNames.append(file.name)
            }
        }

        let delivered = t.deliveredPaths()

        self.init(
            id: t.id_,
            outgoing: t.outgoing,
            peerKey: t.peerKey,
            peerName: t.peerName,
            state: t.state,
            transferred: t.transferred,
            totalSize: t.totalSize,
            createdAtMillis: t.createdAtMillis,
            updatedAtMillis: t.updatedAtMillis,
            isText: t.isText,
            text: text,
            error: t.error,
            reason: t.reason,
            fileNames: fileNames,
            deliveredPaths: delivered.isEmpty ? [] : delivered.components(separatedBy: "\n")
        )
    }
}

/// One outgoing item: a file staged at a path both processes can read.
struct FileDropSendFile: Codable {
    var name: String
    var size: Int64
    var contentType: String
    var path: String
}

/// The payload of a "FileDrop:Send:" provider message.
struct FileDropSendRequest: Codable {
    var peerKey: String
    var peerName: String
    var peerIP: String
    var text: String
    var files: [FileDropSendFile]
}

/// The reply to a "FileDrop:Send:" provider message.
struct FileDropSendResponse: Codable {
    var transferID: String
    var error: String
}

/// Identifiers for the local notification an incoming offer raises. The
/// extension only stamps the category onto its notification; the category and
/// its actions are registered by the app, since categories registered from a
/// Network Extension are not reliably picked up by the system.
enum FileDropNotification {
    static let offerCategory = "io.netbird.filedrop.offer"
    static let acceptAction = "io.netbird.filedrop.accept"
    static let declineAction = "io.netbird.filedrop.decline"
    static let transferIDKey = "transferID"
}
