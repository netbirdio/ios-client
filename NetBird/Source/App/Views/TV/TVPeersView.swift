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

                // Search field
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 24))
                        .foregroundColor(TVColors.textSecondary)

                    TextField("Search peers...", text: $viewModel.peerViewModel.peerFilter)
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
                        .fill(Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(isSearchFocused ? Color.accentColor : Color.white.opacity(0.1), lineWidth: isSearchFocused ? 3 : 1)
                )
                .focused($isSearchFocused)
                .padding(.horizontal, 50)

                // Filter row
                TVFilterBar(
                    options: ["All", "Connected", "Connecting", "Idle"],
                    selected: $viewModel.peerViewModel.selectionFilter
                )
                .padding(.horizontal, 50)
                .padding(.bottom, 10)

                // Peer list (scrollable, focus-navigable)
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(filteredPeers, id: \.id) { peer in
                            TVPeerCard(
                                peer: peer,
                                isSelected: selectedPeer?.id == peer.id,
                                onSelect: { selectedPeer = peer }
                            )
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 20)
                            .fill(Color.white.opacity(0.04))
                    )
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
                VStack(alignment: .leading, spacing: 6) {
                    Text(peer.fqdn)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundColor(isFocused ? .black : TVColors.textPrimary)
                        .lineLimit(1)

                    Text(peer.ip)
                        .font(.system(size: 18, design: .monospaced))
                        .foregroundColor(isFocused ? .black.opacity(0.6) : TVColors.textSecondary)
                }

                Spacer()

                // Connection type badge
                if peer.connStatus == "Connected" {
                    Text(peer.relayed ? "Relayed" : "Direct")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(isFocused ? .black.opacity(0.7) : .white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(isFocused ? Color.black.opacity(0.1) : (peer.relayed ? Color.orange : Color.green))
                        )
                }

                // Selection indicator
                Image(systemName: "chevron.right")
                    .font(.system(size: 20))
                    .foregroundColor(isFocused ? .black.opacity(0.5) : TVColors.textSecondary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isFocused ? Color.white : Color.clear)
            )
        }
        .buttonStyle(TVSettingsButtonStyle())
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
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Peer Details")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundColor(TVColors.textPrimary)
                    .padding(.bottom, 10)

                // Info section
                TVSettingsSection(title: "Info") {
                    TVDetailInfoRow(icon: "desktopcomputer", label: "Hostname", value: peer.fqdn)
                    TVDetailInfoRow(icon: "network", label: "IP Address", value: peer.ip)
                }

                // Connection section
                TVSettingsSection(title: "Connection") {
                    TVDetailInfoRow(
                        icon: peer.connStatus == "Connected" ? "circle.fill" : "circle",
                        label: "Status",
                        value: peer.connStatus,
                        valueColor: statusColor
                    )
                    TVDetailInfoRow(
                        icon: peer.relayed ? "arrow.triangle.swap" : "point.topleft.down.to.point.bottomright.curvepath",
                        label: "Type",
                        value: peer.relayed ? "Relayed" : "Direct"
                    )
                    if !peer.latency.isEmpty && peer.latency != "0ms" {
                        TVDetailInfoRow(icon: "timer", label: "Latency", value: peer.latency)
                    }
                }

                // Routes section
                if !peer.routes.isEmpty {
                    TVSettingsSection(title: "Routes") {
                        ForEach(peer.routes, id: \.self) { route in
                            TVDetailInfoRow(icon: "arrow.triangle.branch", label: "Route", value: route)
                        }
                    }
                }
            }
            .padding(30)
        }
        .background(
            LinearGradient(
                colors: [TVColors.gradientTop, TVColors.gradientBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private var statusColor: Color {
        switch peer.connStatus {
        case "Connected": return .green
        case "Connecting": return .orange
        default: return .gray
        }
    }
}

/// Focusable detail row matching TVSettingsInfoRow style.
struct TVDetailInfoRow: View {
    let icon: String
    let label: String
    let value: String
    var valueColor: Color? = nil

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: {}) {
            HStack(spacing: 20) {
                Image(systemName: icon)
                    .font(.system(size: 28))
                    .foregroundColor(isFocused ? .black.opacity(0.5) : (valueColor ?? TVColors.textSecondary))
                    .frame(width: 40)

                VStack(alignment: .leading, spacing: 6) {
                    Text(label)
                        .font(.system(size: 18))
                        .foregroundColor(isFocused ? .black.opacity(0.5) : TVColors.textSecondary)

                    Text(value)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundColor(isFocused ? .black : (valueColor ?? TVColors.textPrimary))
                        .lineLimit(2)
                }

                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isFocused ? Color.white : Color.clear)
            )
        }
        .buttonStyle(TVSettingsButtonStyle())
        .focused($isFocused)
    }
}

struct TVFilterBar: View {
    let options: [String]
    @Binding var selected: String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { option in
                TVFilterButton(
                    title: option,
                    isSelected: selected == option,
                    action: { selected = option }
                )
            }
            Spacer()
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.white.opacity(0.04))
        )
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
                .font(.system(size: 22, weight: isSelected ? .semibold : .medium))
                .foregroundColor(
                    isFocused ? .black :
                    (isSelected ? TVColors.textPrimary : TVColors.textSecondary)
                )
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(
                            isFocused ? Color.white :
                            (isSelected ? Color.white.opacity(0.1) : Color.clear)
                        )
                )
        }
        .buttonStyle(TVSettingsButtonStyle())
        .focused($isFocused)
    }
}

struct TVNoPeersView: View {
    @State private var showDocsQR = false

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

            Button {
                showDocsQR = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 26))
                    Text("Visit docs.netbird.io")
                        .font(.system(size: 28))
                }
                .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)
            .padding(.top, 20)
        }
        .sheet(isPresented: $showDocsQR) {
            TVQRCodeSheet(
                url: "https://docs.netbird.io",
                title: "Documentation",
                subtitle: "Scan this QR code to visit our docs"
            )
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


