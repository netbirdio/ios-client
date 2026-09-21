//
//  iOSSSHView.swift
//  NetBird
//
//  SSH tab: the list of this profile's SSH sessions, matching the Android
//  client's sessions screen — one row per session with a state bar, a hang-up
//  and a delete button, a context menu for edit and duplicate, and a floating
//  button for a new connection.
//

import SwiftUI

#if os(iOS)

struct iOSSSHView: View {
    @EnvironmentObject private var viewModel: ViewModel
    @ObservedObject private var registry = SSHSessionRegistry.shared

    @State private var connectSheet: SSHConnectRequest?
    @State private var openSessionID: String?
    @State private var pendingDelete: SSHSessionInfo?
    @State private var toast: String?

    var body: some View {
        ZStack {
            Color("BgMenu").ignoresSafeArea()

            if registry.sessions.isEmpty {
                EmptyTabPlaceholder(
                    message: "No SSH sessions yet.\nTap + to start one.",
                    learnMoreURL: nil
                )
            } else {
                sessionList
            }

            newSessionButton
            toastOverlay
        }
        .navigationTitle("SSH Sessions")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $connectSheet) { request in
            SSHConnectSheet(request: request) { host, port, user in
                apply(request: request, host: host, port: port, user: user)
            }
        }
        .fullScreenCover(item: Binding(
            get: { openSessionID.map(SSHTerminalRoute.init(sessionID:)) },
            set: { openSessionID = $0?.sessionID }
        )) { route in
            SSHTerminalView(sessionID: route.sessionID)
        }
        .alert(item: $pendingDelete) { info in
            Alert(
                title: Text("Delete session"),
                message: Text("Delete \(info.label) and discard its output?"),
                primaryButton: .destructive(Text("Delete")) {
                    registry.close(id: info.id)
                },
                secondaryButton: .cancel(Text("Cancel"))
            )
        }
    }

    // MARK: - List

    private var sessionList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(registry.sessions) { info in
                    SSHSessionRow(
                        info: info,
                        onOpen: { open(info) },
                        onDisconnect: { registry.disconnect(id: info.id) },
                        onDelete: { pendingDelete = info },
                        onEdit: { connectSheet = .edit(info) },
                        onDuplicate: { duplicate(info) }
                    )
                }
            }
            .padding(.horizontal)
            .padding(.top, 12)
            // Clears the floating button, which would otherwise cover the last
            // row's buttons.
            .padding(.bottom, 96)
        }
    }

    private var newSessionButton: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button {
                    connectSheet = .new
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 56, height: 56)
                        .background(Circle().fill(Color.orange))
                        .shadow(radius: 4, y: 2)
                }
                .accessibilityLabel("New SSH connection")
                .padding(.trailing, 16)
                .padding(.bottom, 24)
            }
        }
    }

    @ViewBuilder
    private var toastOverlay: some View {
        if let toast {
            VStack {
                Spacer()
                Text(toast)
                    .font(.footnote)
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.black.opacity(0.8)))
                    .padding(.bottom, 100)
            }
            .transition(.opacity)
        }
    }

    // MARK: - Actions

    /// Reconnect on the spot only when the session left nothing behind. With
    /// output to read, just open it and let the terminal's own bar offer the
    /// redial, so the scrollback is not replaced before it has been seen.
    private func open(_ info: SSHSessionInfo) {
        if info.state.isReconnectable && !info.hasScrollback {
            guard registry.reconnect(id: info.id) else {
                show(toast: "NetBird is not running")
                return
            }
        }
        openSessionID = info.id
    }

    private func duplicate(_ info: SSHSessionInfo) {
        guard let copy = registry.duplicate(id: info.id) else {
            show(toast: "NetBird is not running")
            return
        }
        openSessionID = copy.id
    }

    /// - Returns: false when nothing could be done with the details, so the
    ///   form stays open with what was typed still in it.
    private func apply(request: SSHConnectRequest, host: String, port: Int, user: String) -> Bool {
        switch request.mode {
        case .edit(let id):
            guard registry.edit(id: id, host: host, port: port, user: user) else {
                show(toast: "That session is no longer open")
                return false
            }
            return true
        case .connect:
            guard registry.canConnect else {
                show(toast: "NetBird is not running")
                return false
            }
            let handle = registry.create(host: host, port: port, user: user)
            openSessionID = handle.id
            return true
        }
    }

    private func show(toast message: String) {
        withAnimation { toast = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation { if toast == message { toast = nil } }
        }
    }
}

/// Wraps a session id so `fullScreenCover(item:)` can drive the terminal.
private struct SSHTerminalRoute: Identifiable {
    let sessionID: String
    var id: String { sessionID }
}

/// One session row: a coloured state bar, the target, the state line, and the
/// two buttons the Android row carries. Reconnecting is what tapping a finished
/// row already does, so only hanging up needs a button of its own.
private struct SSHSessionRow: View {
    let info: SSHSessionInfo
    let onOpen: () -> Void
    let onDisconnect: () -> Void
    let onDelete: () -> Void
    let onEdit: () -> Void
    let onDuplicate: () -> Void

    private var isDown: Bool { info.state.isReconnectable }

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2.5)
                .fill(stateColor)
                .frame(width: 5)

            VStack(alignment: .leading, spacing: 4) {
                Text(info.label)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(Color("TextPrimary"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(stateLine)
                    .font(.system(size: 12))
                    .foregroundColor(Color("TextSecondary"))
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !isDown {
                Button(action: onDisconnect) {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 18))
                        .foregroundColor(Color("TextPrimary"))
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Disconnect")
            }

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 17))
                    .foregroundColor(Color("TextPrimary"))
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete session")
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color("BgPeerCard")))
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .contextMenu {
            Button("Edit session", action: onEdit)
            Button("Duplicate session", action: onDuplicate)
        }
    }

    private var stateColor: Color {
        switch info.state {
        case .connected: return Color(red: 0.30, green: 0.69, blue: 0.31)   // #4caf50
        case .connecting: return Color(red: 1.0, green: 0.70, blue: 0.0)    // #ffb300
        case .error: return Color(red: 0.90, green: 0.22, blue: 0.21)       // #e53935
        case .needsPassword, .needsHostKeyConfirm: return Color(red: 1.0, green: 0.70, blue: 0.0)
        case .closed: return Color(red: 0.62, green: 0.62, blue: 0.62)      // #9e9e9e
        }
    }

    private var stateLine: String {
        let name: String
        switch info.state {
        case .connecting: name = "connecting"
        case .connected: name = "connected"
        case .needsPassword: name = "password required"
        case .needsHostKeyConfirm: name = "host key confirmation required"
        case .closed: name = "closed"
        case .error: name = "error"
        }
        // A prompt carries an internal marker rather than a message meant for
        // reading, and the label already says what is needed.
        if info.state == .needsPassword || info.state == .needsHostKeyConfirm {
            return name
        }
        return info.stateMessage.isEmpty ? name : "\(name) — \(info.stateMessage)"
    }
}

#endif
