//
//  PeerTabView.swift
//  NetBird
//
//  Created by Pascal Fischer on 06.05.24.
//
//  Shared between iOS and tvOS.
//  tvOS has its own dedicated view (TVPeersView) but this can be used as fallback.
//

import SwiftUI

#if os(iOS)
import UIKit
#endif

struct PeerTabView: View {
    @EnvironmentObject var viewModel: ViewModel
    
    var body: some View {
        ZStack {
            Color("BgMenu")
            VStack {
                Spacer(minLength: 0)
                if viewModel.vpnDisplayState == .connected && viewModel.peerViewModel.peerInfo.count > 0 {
                    VStack {
                        PeerListHeader(peerViewModel: self.viewModel.peerViewModel)
                        PeerListView(peerViewModel: self.viewModel.peerViewModel, viewModel: self.viewModel)
                    }
                } else {
                    NoPeersView()
                }
                Spacer(minLength: 0)
            }
        }
    }
}

struct PeerListHeader: View {
    @ObservedObject var peerViewModel: PeerViewModel
    
    var body: some View {
        HStack {
            CustomTextField(placeholder: "search peers", text: self.$peerViewModel.peerFilter, secure: .constant(false))
                .padding([.top, .bottom], 10)
                .onChange(of: self.peerViewModel.peerFilter) { _ in
                    self.peerViewModel.selectedPeerId = nil
                }
            Menu {
                Button(action: { self.peerViewModel.selectionFilter = "All" }) {
                    Text("All")
                }
                
                Button(action: { self.peerViewModel.selectionFilter = "Connected" }) {
                    Text("Connected")
                }
                Button(action: { self.peerViewModel.selectionFilter = "Connecting" }) {
                    Text("Connecting")
                }
                Button(action: { self.peerViewModel.selectionFilter = "Idle" }) {
                    Text("Idle")
                }
                
            } label: {
                Image("icon-filter")
                    .padding([.leading, .trailing], 4)
            }
            .onChange(of: self.peerViewModel.selectionFilter) { _ in
                self.peerViewModel.selectedPeerId = nil
            }
        }.padding([.leading, .trailing])
    }
}

struct NoPeersView: View {
    var body: some View {
        EmptyTabPlaceholder(
            message: "It looks like there are no machines that you can connect to...",
            learnMoreURL: URL(string: "https://docs.netbird.io")
        )
    }
}

struct PeerListView: View {
    @ObservedObject var peerViewModel: PeerViewModel
    @ObservedObject var viewModel: ViewModel
    @State private var selectedPeer: PeerInfo?

    var body: some View {
        List {
            ForEach(peerViewModel.displayedPeers) { peer in
                PeerCard(peer: peer)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedPeer = peer
                    }
                    #if os(iOS)
                    .contextMenu {
                        Button("Copy FQDN") {
                            UIPasteboard.general.string = peer.fqdn
                            viewModel.showFqdnCopiedAlert = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                withAnimation {
                                    viewModel.showFqdnCopiedAlert = false
                                }
                            }
                        }
                        Button("Copy IP") {
                            UIPasteboard.general.string = peer.ip
                            viewModel.showIpCopiedAlert = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                withAnimation {
                                    viewModel.showIpCopiedAlert = false
                                }
                            }
                        }
                    }
                    #endif
            }
            .listRowBackground(Color("BgMenu"))
        }
        .listStyle(.plain)
        .sheet(item: $selectedPeer) { peer in
            PeerDetailSheet(peer: peer)
        }
    }
}


#Preview {
    PeerTabView()
}
