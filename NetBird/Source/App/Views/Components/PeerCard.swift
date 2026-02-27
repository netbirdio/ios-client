//
//  PeerCard.swift
//  NetBirdiOS
//
//  Created by Pascal Fischer on 10.10.23.
//

import SwiftUI

struct PeerCard: View {
    @ObservedObject var peer: PeerInfo

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(peer.fqdn)
                    .font(.body)
                    .foregroundColor(Color("TextPrimary"))
                    .lineLimit(1)
                Text(peer.ip)
                    .font(.subheadline)
                    .foregroundColor(Color("TextSecondary"))
                    .lineLimit(1)
            }
            Spacer()
            ConnectionIndicator(status: peer.connStatus)
        }
    }
}

struct ConnectionIndicator: View {
    let status: String

    var indicatorColor: Color {
        switch status {
        case "Connected", "Connecting":
            return .green
        default:
            return .gray
        }
    }

    var body: some View {
        Circle()
            .fill(indicatorColor)
            .frame(width: 10, height: 10)
    }
}
