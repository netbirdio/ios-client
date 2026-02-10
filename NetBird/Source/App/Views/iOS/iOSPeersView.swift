//
//  iOSPeersView.swift
//  NetBird
//
//  Peers tab: full-screen wrapper around PeerTabView.
//

import SwiftUI

#if os(iOS)

struct iOSPeersView: View {
    @EnvironmentObject var viewModel: ViewModel

    var body: some View {
        ZStack {
            Color("BgMenu")
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Text(connectedCount + " of " + totalCount)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(Color("TextSecondary"))
                    Text("Peers connected")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundColor(Color("TextSecondary"))
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.top, 16)
                .padding(.bottom, 8)

                PeerTabView()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarHidden(true)
    }

    private var connectedCount: String {
        guard viewModel.vpnDisplayState == .connected else { return "0" }
        return viewModel.peerViewModel.peerInfo.filter { $0.connStatus == "Connected" }.count.description
    }

    private var totalCount: String {
        guard viewModel.vpnDisplayState == .connected else { return "0" }
        return viewModel.peerViewModel.peerInfo.count.description
    }
}

#endif
