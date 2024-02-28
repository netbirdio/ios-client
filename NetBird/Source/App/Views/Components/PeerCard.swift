//
//  PeerCard.swift
//  NetBirdiOS
//
//  Created by Pascal Fischer on 10.10.23.
//

import SwiftUI

struct PeerCard: View {
    var peer: PeerInfo
    
    var body: some View {
        HStack {
            HStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(peer.connStatus == "Connected" ? Color.green : Color.gray.opacity(0.5))
                                .frame(width: 8, height: 40)
                VStack(alignment: .leading, content: {
                    Text(peer.fqdn).padding(.bottom, 1).foregroundColor(Color("TextPeerCard"))
                    Text(peer.ip).foregroundColor(Color("TextPeerCard"))
                }).padding(.leading, 5)
                Spacer()
                Text(peer.connStatus).foregroundColor(Color("TextPeerCard")).padding(.leading, 3)
            }
            .padding()
        }.background(
            Color("BgPeerCard")
        )
    }
}

#Preview {
    PeerCard(peer: PeerInfo(ip: "123.123.123.123", fqdn: "iPhone.netbird.cloud", connStatus: "Connected"))
}
