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
        VStack {
            Image("icon-empty-box")
                .resizable()
                .scaledToFit()
                .frame(height: Screen.height * 0.2)
                .padding(.top, Screen.height * 0.05)

            Text("It looks like there are no machines that you can connect to...")
                .font(.system(size: 18 * Layout.fontScale, weight: .regular))
                .foregroundColor(Color("TextPrimary"))
                .multilineTextAlignment(.center)
                .padding(.horizontal, Screen.width * 0.075)
                .padding(.top, Screen.height * 0.04)

            if let url = URL(string: "https://docs.netbird.io") {
                Link(destination: url) {
                    Text("Learn why")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.accentColor)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.orange.opacity(0.8), lineWidth: 2)
                                )
                        )
                }
                .padding(.top, Screen.height * 0.04)
                .padding(.horizontal, Screen.width * 0.05)
            } else {
                Text("Unable to load the documentation link.")
                    .font(.footnote)
                    .foregroundColor(.red)
                    .padding(.top, Screen.height * 0.04)
            }
        }
        .padding(.horizontal, Screen.width * 0.05)
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
