//
//  iOSSSHView.swift
//  NetBird
//

import SwiftUI

#if os(iOS)

struct iOSSSHView: View {
    @EnvironmentObject private var viewModel: ViewModel
    @EnvironmentObject private var activeStore: SSHActiveSessionStore
    @EnvironmentObject private var sessionStore: SSHSessionStore

    @State private var selectedActive: SSHSessionViewModel?
    @State private var connectTarget: SavedSSHSession?
    @State private var sshPeer: PeerInfo?

    private var connectedPeers: [PeerInfo] {
        viewModel.peerViewModel.peerInfo.filter { $0.connStatus == "Connected" && !$0.ip.isEmpty }
    }

    private var hasContent: Bool {
        !activeStore.sessions.isEmpty || !sessionStore.sessions.isEmpty || !connectedPeers.isEmpty
    }

    var body: some View {
        Group {
            if hasContent {
                sessionList
            } else {
                emptyState
            }
        }
        .navigationTitle("SSH")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $selectedActive) { session in
            SSHTerminalView(viewModel: session)
        }
        .sheet(item: $connectTarget) { session in
            SSHConnectSheet(
                networkExtensionAdapter: viewModel.networkExtensionAdapter,
                host: session.host,
                port: session.port,
                user: session.user,
                password: SSHKeychainStore.load(for: session.id) ?? ""
            )
        }
        .sheet(item: $sshPeer) { peer in
            SSHConnectSheet(
                networkExtensionAdapter: viewModel.networkExtensionAdapter,
                isPeerContext: true,
                peerName: peer.fqdn,
                host: peer.ip
            )
        }
    }

    // MARK: - List

    private var sessionList: some View {
        List {
            if !activeStore.sessions.isEmpty {
                activeSection
            }

            if !connectedPeers.isEmpty {
                peersSection
            }

            if !sessionStore.sessions.isEmpty {
                savedSection
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Active Sessions

    private var activeSection: some View {
        Section {
            ForEach(activeStore.sessions) { session in
                Button {
                    selectedActive = session
                } label: {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(sessionStatusColor(session.state))
                            .frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(session.user)@\(session.host)")
                                .foregroundColor(Color("TextPrimary"))
                                .font(.body)
                            Text(sessionStatusLabel(session.state))
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
            .onDelete { offsets in
                offsets.map { activeStore.sessions[$0].sessionID }
                    .forEach { activeStore.remove(id: $0) }
            }
        } header: {
            sectionHeader("Active", systemImage: "terminal.fill", color: .accentColor)
        }
    }

    // MARK: - Peers Quick Connect

    private var peersSection: some View {
        Section {
            ForEach(connectedPeers) { peer in
                Button {
                    sshPeer = peer
                } label: {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(peer.fqdn.isEmpty ? peer.ip : peer.fqdn)
                                .foregroundColor(Color("TextPrimary"))
                                .font(.body)
                                .lineLimit(1)
                            Text(peer.ip)
                                .foregroundColor(.secondary)
                                .font(.system(.caption, design: .monospaced))
                        }
                        Spacer()
                        Label("SSH", systemImage: "terminal")
                            .font(.caption.weight(.medium))
                            .foregroundColor(.accentColor)
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            sectionHeader("Peers", systemImage: "person.3.fill", color: .orange)
        }
    }

    // MARK: - Saved Sessions

    private var savedSection: some View {
        Section {
            ForEach(sessionStore.sessions) { session in
                Button {
                    connectTarget = session
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "bookmark.fill")
                            .foregroundColor(.accentColor)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(session.name)
                                .foregroundColor(Color("TextPrimary"))
                                .font(.body)
                            Text("\(session.user)@\(session.host):\(session.port)")
                                .foregroundColor(.secondary)
                                .font(.system(.caption, design: .monospaced))
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
            .onDelete { offsets in
                let ids = offsets.map { sessionStore.sessions[$0].id }
                ids.forEach { sessionStore.delete(id: $0) }
            }
        } header: {
            sectionHeader("Saved", systemImage: "bookmark.fill", color: .orange)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "terminal")
                .font(.system(size: 56))
                .foregroundColor(.secondary)

            VStack(spacing: 8) {
                Text("No SSH sessions")
                    .font(.title3.weight(.semibold))
                    .foregroundColor(Color("TextPrimary"))
                Text("Connect to NetBird to see your peers,\nor open a peer's details to start an SSH session.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func sectionHeader(_ title: String, systemImage: String, color: Color) -> some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(color)
                    .frame(width: 24, height: 24)
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
            }
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(Color("TextPrimary"))
        }
        .textCase(nil)
        .padding(.bottom, 2)
    }

    private func sessionStatusColor(_ state: SSHConnectionState) -> Color {
        switch state {
        case .connected:        return .green
        case .connecting:       return .orange
        case .closed, .failed:  return .red
        }
    }

    private func sessionStatusLabel(_ state: SSHConnectionState) -> String {
        switch state {
        case .connected:             return "Connected"
        case .connecting:            return "Connecting…"
        case .closed(let reason):    return "Closed: \(reason)"
        case .failed(let message):   return "Failed: \(message)"
        }
    }
}

#endif
