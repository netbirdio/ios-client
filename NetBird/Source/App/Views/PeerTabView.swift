//
//  PeerTabView.swift
//  NetBird
//
//  Created by Pascal Fischer on 06.05.24.
//

import SwiftUI

struct PeerTabView: View {
    @EnvironmentObject var viewModel: ViewModel
    
    var body: some View {
        ZStack {
            Color("BgMenu")
            VStack {
                Spacer(minLength: 0)
                if viewModel.extensionStateText == "Connected" && viewModel.peerViewModel.peerInfo.count > 0 {
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
                Button(action: { self.peerViewModel.selectionFilter = "Disconnected" }) {
                    Text("Disconnected")
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
        Group {
            Image("icon-empty-box")
                .padding(.top, UIScreen.main.bounds.height * 0.05)
            Text("It looks like there are no machines that you can connect to...")
                .font(.system(size: 18, weight: .regular))
                .foregroundColor(Color("TextPrimary"))
                .multilineTextAlignment(.center)
                .padding(.top, UIScreen.main.bounds.height * 0.04)
                .padding([.leading, .trailing], UIScreen.main.bounds.width * 0.075)
            Link(destination: URL(string: "https://docs.netbird.io")!) {
                Text("Learn why")
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding()
                    .frame(maxWidth: .infinity) // Span the whole width
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.accentColor)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(Color.orange.darker(), lineWidth: 2)
                            )
                    )
                .padding(.top, UIScreen.main.bounds.height * 0.04)
            }
        }
        .padding([.leading, .trailing], UIScreen.main.bounds.width * 0.05)
    }
}

struct PeerListView: View {
    @ObservedObject var peerViewModel: PeerViewModel
    @ObservedObject var viewModel: ViewModel
        
    var body: some View {
        ScrollView {
            VStack {
                ForEach(Array(self.peerViewModel.filteredPeers.enumerated()), id: \.element.id) { index, peer in
                    PeerCard(
                        peer: peer,
                        selectedPeerId: $peerViewModel.selectedPeerId,
                        orientationTop: index > 3
                    )
                    .zIndex(peerViewModel.selectedPeerId == peer.id ? 1 : 0)
                    .opacity(self.peerViewModel.tappedPeer == peer ? 0.3 : 1.0)
                    .onTapGesture {
                        withAnimation {
                            print("Setting selected peer id to \(peer.id)")
                            peerViewModel.selectedPeerId = peerViewModel.selectedPeerId == peer.id ? nil : peer.id
                        }
                    }
                    .onLongPressGesture {
                        peerViewModel.tappedPeer = peer
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            withAnimation {
                                peerViewModel.tappedPeer = nil
                            }
                        }

                        print("Copied to clipboard")
                        UIPasteboard.general.string = peer.fqdn
                        self.viewModel.showCopiedAlert = true

                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            withAnimation {
                                self.viewModel.showCopiedAlert = false
                            }
                        }
                    }
                }
                if self.peerViewModel.peerInfo.count < 4 {
                    Color.clear.frame(height: 80)
                }
            }
            .padding(.bottom, 20)
        }
    }
}


#Preview {
    PeerTabView()
}
