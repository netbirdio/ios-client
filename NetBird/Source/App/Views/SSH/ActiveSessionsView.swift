//
//  ActiveSessionsView.swift
//  NetBird
//

import SwiftUI

#if os(iOS)

struct ActiveSessionsView: View {
    @EnvironmentObject private var activeStore: SSHActiveSessionStore
    @Environment(\.presentationMode) private var presentationMode
    @State private var selectedSession: SSHSessionViewModel?

    var body: some View {
        NavigationView {
            Group {
                if activeStore.sessions.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "terminal")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("No active sessions")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text("Connect to a peer from the Peers tab.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(activeStore.sessions) { session in
                            Button {
                                selectedSession = session
                            } label: {
                                HStack(spacing: 12) {
                                    Circle()
                                        .fill(statusColor(for: session.state))
                                        .frame(width: 10, height: 10)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("\(session.user)@\(session.host)")
                                            .foregroundColor(Color("TextPrimary"))
                                            .font(.body)
                                        Text(statusLabel(for: session.state))
                                            .foregroundColor(.secondary)
                                            .font(.caption)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                        .onDelete { offsets in
                            offsets.map { activeStore.sessions[$0].sessionID }
                                .forEach { activeStore.remove(id: $0) }
                        }
                    }
                }
            }
            .navigationTitle("Active Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { presentationMode.wrappedValue.dismiss() }
                }
            }
        }
        .fullScreenCover(item: $selectedSession) { session in
            SSHTerminalView(viewModel: session)
        }
    }

    private func statusColor(for state: SSHConnectionState) -> Color {
        switch state {
        case .connected:          return .green
        case .connecting:         return .orange
        case .closed, .failed:    return .red
        }
    }

    private func statusLabel(for state: SSHConnectionState) -> String {
        switch state {
        case .connected:             return "Connected"
        case .connecting:            return "Connecting…"
        case .closed(let reason):    return "Closed: \(reason)"
        case .failed(let message):   return "Failed: \(message)"
        }
    }
}

#endif
