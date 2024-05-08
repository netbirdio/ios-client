//
//  PeerViewModel.swift
//  NetBird
//
//  Created by Pascal Fischer on 25.04.24.
//

import Combine

class PeerViewModel: ObservableObject {
    @Published var peerInfo: [PeerInfo] = []  
    @Published var selectionFilter: String = "All"
    @Published var peerFilter: String = ""
    
    @Published var tappedPeer: PeerInfo? = nil
    @Published var selectedPeerId: UUID?

    var filteredPeers: [PeerInfo] {
        peerInfo.filter { peer in
            switch selectionFilter {
            case "All": return true
            case "Connected": return peer.connStatus == "Connected"
            case "Disconnected": return peer.connStatus == "Disconnected"
            default: return false
            }
        }
        .filter { peer in
            peer.fqdn.lowercased().contains(peerFilter.lowercased()) ||
            peer.ip.contains(peerFilter) ||
            peerFilter.isEmpty
        }
    }

}

