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

    var body: some View {
        ScrollView {
            VStack {
                ForEach(Array(peerViewModel.displayedPeers.enumerated()), id: \.element.id) { index, peer in
                    PeerCardView(
                        peer: peer,
                        index: index,
                        peerViewModel: peerViewModel,
                        viewModel: viewModel
                    )
                }
                
                if peerViewModel.peerInfo.count < 4 {
                    Color.clear.frame(height: 80)
                }
            }
            .padding(.bottom, 20)
        }
    }
}

struct PeerCardView: View {
    let peer: PeerInfo
    let index: Int
    @ObservedObject var peerViewModel: PeerViewModel
    @ObservedObject var viewModel: ViewModel

    var body: some View {
        PeerCard(
            peer: peer,
            selectedPeerId: $peerViewModel.selectedPeerId,
            orientationTop: index > 3
        )
        .zIndex(peerViewModel.selectedPeerId == peer.id ? 1 : 0)
        .opacity(peerViewModel.tappedPeer == peer ? 0.3 : 1.0)
        .gesture(
            ExclusiveGesture(longPressGesture(for: peer), tapGesture(for: peer))
        )
        .contextMenu {
            contextMenu(for: peer)
        }
    }

    private func longPressGesture(for peer: PeerInfo) -> some Gesture {
        LongPressGesture(minimumDuration: 0.1)
            .onEnded { _ in
                print("long press ended")
                let currLockID = UUID().uuidString
                peerViewModel.lockID = currLockID
                
                self.peerViewModel.freezeDisplayedPeerList()
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                    if currLockID == peerViewModel.lockID {
                        peerViewModel.unfreezeDisplayedPeerList()
                    }
                    
                }
            }
    }

    private func tapGesture(for peer: PeerInfo) -> some Gesture {
        TapGesture(count: 1)
            .onEnded {
                withAnimation {
                    print("Setting selected peer id to \(peer.id)")
                    peerViewModel.selectedPeerId = peerViewModel.selectedPeerId == peer.id ? nil : peer.id
                }
            }
    }

    private func contextMenu(for peer: PeerInfo) -> some View {
        Group {
            #if os(iOS)
            // Clipboard is only available on iOS
            Button("Copy FQDN") {
                UIPasteboard.general.string = peer.fqdn
                print("Copied FQDN to clipboard")
                viewModel.showFqdnCopiedAlert = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    withAnimation {
                        viewModel.showFqdnCopiedAlert = false
                    }
                }
                peerViewModel.unfreezeDisplayedPeerList()
            }

            Button("Copy IP") {
                UIPasteboard.general.string = peer.ip
                print("Copied IP to clipboard")
                viewModel.showIpCopiedAlert = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    withAnimation {
                        viewModel.showIpCopiedAlert = false
                    }
                }
                peerViewModel.unfreezeDisplayedPeerList()
            }
            #else
            // tvOS: Show info instead of copy (no clipboard)
            Text("FQDN: \(peer.fqdn)")
            Text("IP: \(peer.ip)")
            #endif
        }
    }
}


#Preview {
    PeerTabView()
}
