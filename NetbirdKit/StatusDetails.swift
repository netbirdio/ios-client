//
//  StatusDetails.swift
//  NetBirdiOS
//
//  Created by Pascal Fischer on 10.10.23.
//

import Foundation

struct StatusDetails: Codable {
    var ip: String
    var fqdn: String
    var managementStatus: ClientState
    var peerInfo: [PeerInfo]
}

struct PeerInfo: Codable, Identifiable, Equatable {
    var id = UUID()
    var ip: String
    var fqdn: String
    var connStatus: String
}
