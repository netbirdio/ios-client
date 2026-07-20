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
    @EnvironmentObject var activeSessionStore: SSHActiveSessionStore
    @State private var showSavedSessions = false
    @State private var showActiveSessions = false

    var body: some View {
        ZStack {
            Color("BgMenu")
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Text(connectedCount + " of " + totalCount)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(Color("TextPrimary"))
                    Text("Peers connected")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundColor(Color("TextPrimary"))
                    Spacer()
                    Button {
                        showActiveSessions = true
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "terminal")
                                .foregroundColor(Color("TextPrimary"))
                            if !activeSessionStore.sessions.isEmpty {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 8, height: 8)
                                    .offset(x: 4, y: -4)
                            }
                        }
                    }
                    Button {
                        showSavedSessions = true
                    } label: {
                        Image(systemName: "bookmark")
                            .foregroundColor(Color("TextPrimary"))
                    }
                }
                .padding(.horizontal)
                .padding(.top, 16)
                .padding(.bottom, 8)

                PeerTabView()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarHidden(true)
        .sheet(isPresented: $showActiveSessions) {
            ActiveSessionsView()
        }
        .sheet(isPresented: $showSavedSessions) {
            SavedSessionsListView(networkExtensionAdapter: viewModel.networkExtensionAdapter)
        }
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
