//
//  TVPeersView.swift
//  NetBird
//
//  Peers list view optimized for Apple TV.
//
//  Key differences from iOS PeerTabView:
//  - No swipe gestures or context menus (tvOS uses focus + select)
//  - Larger cards for readability from distance
//  - Focus-based selection instead of tap
//  - No clipboard (tvOS limitation)
//

import SwiftUI
import UIKit

#if os(tvOS)

struct TVPeersView: View {
    @EnvironmentObject var viewModel: ViewModel

    var body: some View {
        ZStack {
            TVGradientBackground()

            if viewModel.extensionStateText == "Connected" &&
               viewModel.peerViewModel.peerInfo.count > 0 {
                TVPeerListContent()
            } else {
                TVNoPeersView()
            }
        }
    }
}

struct TVPeerListContent: View {
    @EnvironmentObject var viewModel: ViewModel

    /// Currently selected peer for detail view
    @State private var selectedPeer: PeerInfo?

    @FocusState private var isSearchFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            // Left Side - Peer List
            VStack(alignment: .leading, spacing: 20) {
                // Header with count
                HStack {
                    Text("Peers")
                        .font(.system(size: 48, weight: .bold))
                        .foregroundColor(TVColors.textPrimary)

                    Spacer()

                    Text("\(connectedCount) of \(totalCount) connected")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundColor(TVColors.textSecondary)
                }
                .padding(.horizontal, 50)
                .padding(.top, 40)

                // Search + Filter row
                HStack(spacing: 20) {
                    // Search field
                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 24))
                            .foregroundColor(TVColors.textSecondary)

                        TextField("Search peers...", text: $viewModel.peerViewModel.peerFilter)
                            .textFieldStyle(.plain)
                            .font(.system(size: 28))
                            .foregroundColor(TVColors.textPrimary)
                            .autocorrectionDisabled()
                            .onChange(of: viewModel.peerViewModel.peerFilter) { _ in
                                selectedPeer = nil
                            }

                        if !viewModel.peerViewModel.peerFilter.isEmpty {
                            Button {
                                viewModel.peerViewModel.peerFilter = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 24))
                                    .foregroundColor(TVColors.textSecondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(20)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(TVColors.bgPrimary)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(isSearchFocused ? Color.accentColor : Color.clear, lineWidth: 3)
                    )
                    .focused($isSearchFocused)
                    .frame(maxWidth: 500)

                    TVFilterBar(
                        options: ["All", "Connected", "Connecting", "Idle"],
                        selected: $viewModel.peerViewModel.selectionFilter
                    )
                }
                .padding(.horizontal, 50)
                .padding(.bottom, 30)

                // Peer list (scrollable, focus-navigable)
                ScrollView {
                    LazyVStack(spacing: 15) {
                        ForEach(filteredPeers, id: \.id) { peer in
                            TVPeerCard(
                                peer: peer,
                                isSelected: selectedPeer?.id == peer.id,
                                onSelect: { selectedPeer = peer }
                            )
                        }
                    }
                    .padding(.top, 15)
                    .padding(.horizontal, 50)
                    .padding(.bottom, 50)
                }
            }
            .frame(maxWidth: .infinity)
            
            // Right Side - Peer Details
            if let peer = selectedPeer {
                TVPeerDetailView(peer: peer)
                    .frame(width: 500)
                    .transition(.move(edge: .trailing))
            }
        }
    }
    
    // Computed Properties
    
    private var connectedCount: Int {
        viewModel.peerViewModel.peerInfo.filter { $0.connStatus == "Connected" }.count
    }
    
    private var totalCount: Int {
        viewModel.peerViewModel.peerInfo.count
    }
    
    private var filteredPeers: [PeerInfo] {
        viewModel.peerViewModel.displayedPeers
    }
}

// Individual Peer Card
struct TVPeerCard: View {
    let peer: PeerInfo
    let isSelected: Bool
    let onSelect: () -> Void
    
    @FocusState private var isFocused: Bool
    
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 20) {
                // Status indicator
                Circle()
                    .fill(statusColor)
                    .frame(width: 16, height: 16)
                
                // Peer info
                VStack(alignment: .leading, spacing: 8) {
                    Text(peer.fqdn)
                        .font(.system(size: 32, weight: .bold))
                        .foregroundColor(TVColors.textPrimary)
                        .lineLimit(1)

                    Text(peer.ip)
                        .font(.system(size: 28, weight: .medium, design: .monospaced))
                        .foregroundColor(TVColors.textSecondary)
                }
                
                Spacer()
                
                // Connection type badge
                if peer.connStatus == "Connected" {
                    Text(peer.relayed ? "Relayed" : "Direct")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .fill(peer.relayed ? Color.orange : Color.green)
                        )
                }
                
                // Selection indicator
                Image(systemName: "chevron.right")
                    .font(.system(size: 24))
                    .foregroundColor(TVColors.textSecondary)
            }
            .padding(25)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(isSelected || isFocused ? Color.accentColor.opacity(0.2) : TVColors.bgPrimary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isFocused ? Color.accentColor : Color.clear, lineWidth: 4)
            )
            .scaleEffect(isFocused ? 1.02 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isFocused)
        }
        .buttonStyle(.plain)
        .focused($isFocused)
    }
    
    private var statusColor: Color {
        switch peer.connStatus {
        case "Connected": return .green
        case "Connecting": return .orange
        default: return .gray
        }
    }
}

// Peer Detail Panel
struct TVPeerDetailView: View {
    let peer: PeerInfo
    
    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            Text("Peer Details")
                .font(.system(size: 36, weight: .bold))
                .foregroundColor(TVColors.textPrimary)
            
            Divider()
            
            // Details list
            Group {
                TVDetailRow(label: "Hostname", value: peer.fqdn)
                TVDetailRow(label: "IP Address", value: peer.ip)
                TVDetailRow(label: "Status", value: peer.connStatus)
                TVDetailRow(label: "Connection", value: peer.relayed ? "Relayed" : "Direct")
                
                if !peer.routes.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Routes")
                            .font(.system(size: 26, weight: .medium))
                            .foregroundColor(TVColors.textSecondary)

                        ForEach(peer.routes, id: \.self) { route in
                            Text(route)
                                .font(.system(size: 28, design: .monospaced))
                                .foregroundColor(TVColors.textPrimary)
                        }
                    }
                }
            }
            
            Spacer()
        }
        .padding(40)
        .background(TVColors.bgSideDrawer)
    }
}

struct TVDetailRow: View {
    let label: String
    let value: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.system(size: 26, weight: .medium))
                .foregroundColor(TVColors.textSecondary)

            Text(value)
                .font(.system(size: 32, weight: .semibold))
                .foregroundColor(TVColors.textPrimary)
        }
    }
}

struct TVFilterBar: View {
    let options: [String]
    @Binding var selected: String

    var body: some View {
        HStack(spacing: 35) {
            ForEach(options, id: \.self) { option in
                TVFilterButton(
                    title: option,
                    isSelected: selected == option,
                    action: { selected = option }
                )
            }
            Spacer()
        }
    }
}

struct TVFilterButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 28, weight: isSelected || isFocused ? .semibold : .regular))
                .foregroundColor(isSelected || isFocused ? .white : TVColors.textSecondary)
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.accentColor : (isFocused ? Color.gray.opacity(0.5) : TVColors.bgPrimary))
                )
                .scaleEffect(isFocused ? 1.05 : 1.0)
                .animation(.easeInOut(duration: 0.15), value: isFocused)
        }
        .buttonStyle(.plain)
        .focused($isFocused)
    }
}

struct TVNoPeersView: View {
    var body: some View {
        VStack(spacing: 40) {
            Image("icon-empty-box")
                .resizable()
                .scaledToFit()
                .frame(height: 200)
            
            Text("No Peers Available")
                .font(.system(size: 44, weight: .bold))
                .foregroundColor(TVColors.textPrimary)

            Text("Connect to NetBird to see your peers,\nor add devices to your network.")
                .font(.system(size: 32))
                .foregroundColor(TVColors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 600)
        }
    }
}

struct TVPeersView_Previews: PreviewProvider {
    static var previews: some View {
        TVPeersView()
            .environmentObject(ViewModel())
    }
}

#endif


