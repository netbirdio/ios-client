//
//  StatusDetails.swift
//  NetBirdiOS
//
//  Created by Pascal Fischer on 10.10.23.
//

import Foundation
import Combine

struct StatusDetails: Codable {
    var ip: String
    var fqdn: String
    var managementStatus: ClientState
    var peerInfo: [PeerInfo]
}

extension StatusDetails: Equatable {
    static func == (lhs: StatusDetails, rhs: StatusDetails) -> Bool {
        return lhs.ip == rhs.ip &&
               lhs.fqdn == rhs.fqdn &&
               lhs.managementStatus == rhs.managementStatus &&
               lhs.peerInfo == rhs.peerInfo
    }
}

class PeerInfo: ObservableObject, Codable, Identifiable {
    var id = UUID()
    var ip: String
    var fqdn: String
    var localIceCandidateEndpoint: String
    var remoteIceCandidateEndpoint: String
    var localIceCandidateType: String
    var remoteIceCandidateType: String
    var pubKey: String
    var latency: String
    var bytesRx: Int64
    var bytesTx: Int64
    var connStatus: String
    var connStatusUpdate: String
    var direct: Bool
    var lastWireguardHandshake: String
    var relayed: Bool
    var rosenpassEnabled: Bool
    var routes: [String]
    var selected: Bool = false
    
    init(ip: String, fqdn: String, localIceCandidateEndpoint: String, remoteIceCandidateEndpoint: String,
             localIceCandidateType: String, remoteIceCandidateType: String, pubKey: String, latency: String,
             bytesRx: Int64, bytesTx: Int64, connStatus: String, connStatusUpdate: String, direct: Bool,
         lastWireguardHandshake: String, relayed: Bool, rosenpassEnabled: Bool, routes: [String]) {
            self.ip = ip
            self.fqdn = fqdn
            self.localIceCandidateEndpoint = localIceCandidateEndpoint
            self.remoteIceCandidateEndpoint = remoteIceCandidateEndpoint
            self.localIceCandidateType = localIceCandidateType
            self.remoteIceCandidateType = remoteIceCandidateType
            self.pubKey = pubKey
            self.latency = latency
            self.bytesRx = bytesRx
            self.bytesTx = bytesTx
            self.connStatus = connStatus
            self.connStatusUpdate = connStatusUpdate
            self.direct = direct
            self.lastWireguardHandshake = lastWireguardHandshake
            self.relayed = relayed
            self.rosenpassEnabled = rosenpassEnabled
            self.routes = routes
        }
}

extension PeerInfo: Equatable {
    static func == (lhs: PeerInfo, rhs: PeerInfo) -> Bool {
        return lhs.id == rhs.id &&
               lhs.ip == rhs.ip &&
               lhs.fqdn == rhs.fqdn &&
               lhs.localIceCandidateEndpoint == rhs.localIceCandidateEndpoint &&
               lhs.remoteIceCandidateEndpoint == rhs.remoteIceCandidateEndpoint &&
               lhs.localIceCandidateType == rhs.localIceCandidateType &&
               lhs.remoteIceCandidateType == rhs.remoteIceCandidateType &&
               lhs.pubKey == rhs.pubKey &&
               lhs.latency == rhs.latency &&
               lhs.bytesRx == rhs.bytesRx &&
               lhs.bytesTx == rhs.bytesTx &&
               lhs.connStatus == rhs.connStatus &&
               lhs.connStatusUpdate == rhs.connStatusUpdate &&
               lhs.direct == rhs.direct &&
               lhs.lastWireguardHandshake == rhs.lastWireguardHandshake &&
               lhs.relayed == rhs.relayed &&
               lhs.rosenpassEnabled == rhs.rosenpassEnabled &&
               Set(lhs.routes) == Set(rhs.routes)
    }
}

extension PeerInfo {
    func update(from newInfo: PeerInfo) {
        self.ip = newInfo.ip
        self.fqdn = newInfo.fqdn
        self.localIceCandidateEndpoint = newInfo.localIceCandidateEndpoint
        self.remoteIceCandidateEndpoint = newInfo.remoteIceCandidateEndpoint
        self.localIceCandidateType = newInfo.localIceCandidateType
        self.remoteIceCandidateType = newInfo.remoteIceCandidateType
        self.pubKey = newInfo.pubKey
        self.latency = newInfo.latency
        self.bytesRx = newInfo.bytesRx
        self.bytesTx = newInfo.bytesTx
        self.connStatus = newInfo.connStatus
        self.connStatusUpdate = newInfo.connStatusUpdate
        self.direct = newInfo.direct
        self.lastWireguardHandshake = newInfo.lastWireguardHandshake
        self.relayed = newInfo.relayed
        self.rosenpassEnabled = newInfo.rosenpassEnabled
        self.routes = newInfo.routes
        self.selected = newInfo.selected
    }
}

struct Item: Identifiable {
    let id = UUID()
    var name: String
    var value: String
    var isEnabled: Bool
}
