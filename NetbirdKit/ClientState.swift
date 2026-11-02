//
//  ClientState.swift
//  NetBird
//
//  Created by Pascal Fischer on 09.11.23.
//

import NetBirdSDK

enum ClientState: Codable, CustomStringConvertible, Hashable {
    case connected
    case connecting
    case disconnected
    case disconnecting
    case noNetwork

    init?(sdkState: Int) {
        switch sdkState {
        case NetBirdSDKClientStateConnected: self = .connected
        case NetBirdSDKClientStateConnecting: self = .connecting
        case NetBirdSDKClientStateDisconnected: self = .disconnected
        case NetBirdSDKClientStateDisconnecting: self = .disconnecting
        case NetBirdSDKClientStateNoNetwork: self = .noNetwork
        default: return nil
        }
    }

    var description: String {
        switch self {
        case .connected:
            return "Connected"
        case .connecting:
            return "Connecting..."
        case .disconnected:
            return "Disconnected"
        case .noNetwork:
            return "No network"
        case .disconnecting:
            return "Disconnecting..."
        }
    }
}

