//
//  SavedSessionsListView.swift
//  NetBird
//

import SwiftUI

#if os(iOS)

struct SavedSessionsListView: View {
    let networkExtensionAdapter: NetworkExtensionAdapter

    @EnvironmentObject private var sessionStore: SSHSessionStore
    @Environment(\.presentationMode) private var presentationMode

    @State private var connectTarget: SavedSSHSession?

    var body: some View {
        NavigationView {
            Group {
                if sessionStore.sessions.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "terminal")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("No saved sessions")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text("Tap + on the Peers tab to connect to any host, or use SSH on a peer's detail screen.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(sessionStore.sessions) { session in
                            Button {
                                connectTarget = session
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(session.name)
                                        .foregroundColor(Color("TextPrimary"))
                                        .font(.body)
                                    Text("\(session.user)@\(session.host):\(session.port)")
                                        .foregroundColor(.secondary)
                                        .font(.caption)
                                        
                                }
                                .padding(.vertical, 2)
                            }
                        }
                        .onDelete { offsets in
                            let ids = offsets.map { sessionStore.sessions[$0].id }
                            ids.forEach { sessionStore.delete(id: $0) }
                        }
                    }
                }
            }
            .navigationTitle("Saved Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { presentationMode.wrappedValue.dismiss() }
                }
            }
        }
        .sheet(item: $connectTarget) { session in
            SSHConnectSheet(
                networkExtensionAdapter: networkExtensionAdapter,
                host: session.host,
                port: session.port,
                user: session.user,
                password: SSHKeychainStore.load(for: session.id) ?? ""
            )
        }
    }
}

#endif
