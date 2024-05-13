//
//  ClientState.swift
//  NetBird
//
//  Created by Pascal Fischer on 09.11.23.
//

enum ClientState: Codable, CustomStringConvertible, Hashable {
    case connected
    case connecting
    case disconnected
    case disconnecting

    var description: String {
        switch self {
        case .connected:
            return "Connected"
        case .connecting:
            return "Connecting..."
        case .disconnected:
            return "Disconnected"
        case .disconnecting:
            return "Disconnecting..."
        }
    }
}

