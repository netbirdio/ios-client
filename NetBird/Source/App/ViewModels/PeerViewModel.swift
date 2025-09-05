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
    
    @Published var freezeDisplayedPeers: Bool = false
    private var displayedPeersBackup: [PeerInfo] = []
    var lockID: String = UUID().uuidString
    
    var filteredPeers: [PeerInfo] {
        return peerInfo.filter { peer in
            switch selectionFilter {
            case "All": return true
            case "Connected": return peer.connStatus == "Connected"
            case "Connecting": return peer.connStatus == "Connecting"
            case "Idle": return peer.connStatus == "Idle"
            default: return false
            }
        }
        .filter { peer in
            peer.fqdn.lowercased().contains(peerFilter.lowercased()) ||
            peer.ip.contains(peerFilter) ||
            peerFilter.isEmpty
        }
    }
    
    var displayedPeers: [PeerInfo] {
        if freezeDisplayedPeers {
            return displayedPeersBackup
        } else {
            displayedPeersBackup = filteredPeers
            let conn = filteredPeers.filter{ peer in
                peer.connStatus == "Connected"
            }
            return filteredPeers
        }
    }
    
    func freezeDisplayedPeerList() {
        self.freezeDisplayedPeers = true
        print("Freezing displayed peer list")
    }
    
    func unfreezeDisplayedPeerList() {
        self.freezeDisplayedPeers = false
        print("Unfreezing displayed peer list")
    }

}

