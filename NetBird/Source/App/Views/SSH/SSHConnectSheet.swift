//
//  SSHConnectSheet.swift
//  NetBird
//
//  Prompts for SSH connection parameters, for a fresh connection or to retarget
//  a stored session. No password is asked for here: the Go client detects the
//  server type and picks the auth, and only a server that refuses everything
//  else makes the terminal prompt for one.
//

import SwiftUI

#if os(iOS)

/// What the sheet is being opened for.
struct SSHConnectRequest: Identifiable {
    enum Mode {
        case connect
        /// Retargets the stored session with this id.
        case edit(String)
    }

    let id = UUID()
    let mode: Mode
    let title: String
    /// Non-nil for a NetBird peer, whose address is fixed; the field is then
    /// shown read-only so the target is visible but not editable.
    let fixedHost: String?
    let initialHost: String
    let initialPort: Int
    let initialUser: String?

    static var new: SSHConnectRequest {
        SSHConnectRequest(mode: .connect,
                          title: "New SSH connection",
                          fixedHost: nil,
                          initialHost: "",
                          initialPort: SSHDefaults.port,
                          initialUser: nil)
    }

    /// Opened from a peer: the address is the peer's overlay IP.
    static func peer(name: String, ip: String) -> SSHConnectRequest {
        SSHConnectRequest(mode: .connect,
                          title: "SSH to \(name)",
                          fixedHost: ip,
                          initialHost: ip,
                          initialPort: SSHDefaults.port,
                          initialUser: nil)
    }

    /// The host is editable here even for a peer session, which is the point:
    /// the saved entry is what is being corrected.
    static func edit(_ info: SSHSessionInfo) -> SSHConnectRequest {
        SSHConnectRequest(mode: .edit(info.id),
                          title: "Edit session",
                          fixedHost: nil,
                          initialHost: info.host,
                          initialPort: info.port,
                          initialUser: info.user)
    }

    var confirmTitle: String {
        if case .edit = mode { return "Save" }
        return "Connect"
    }
}

enum SSHDefaults {
    /// Both a NetBird peer's built-in server and an ordinary one listen here.
    static let port = 22
    static let maxPort = 65535
}

struct SSHConnectSheet: View {
    let request: SSHConnectRequest
    let onConfirm: (String, Int, String) -> Void

    @Environment(\.presentationMode) private var presentationMode

    @State private var host: String
    @State private var user: String
    @State private var port: String
    @State private var hostError: String?
    @State private var userError: String?
    @State private var portError: String?

    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case host, user, port }

    init(request: SSHConnectRequest, onConfirm: @escaping (String, Int, String) -> Void) {
        self.request = request
        self.onConfirm = onConfirm
        _host = State(initialValue: request.initialHost)
        // An editor starts from the session's own name; otherwise prefill with
        // whatever was used last, so a repeat connection is one tap. Left empty
        // on a fresh install rather than guessing a name.
        _user = State(initialValue: request.initialUser ?? SSHSessionStore.lastUser)
        _port = State(initialValue: String(request.initialPort))
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    if request.fixedHost == nil {
                        field("Host (IP or FQDN)", text: $host, error: hostError, field: .host)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    } else {
                        HStack {
                            Text("Host")
                                .foregroundColor(Color("TextSecondary"))
                            Spacer()
                            Text(host)
                                .foregroundColor(Color("TextPrimary"))
                        }
                    }

                    field("Username", text: $user, error: userError, field: .user)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    field("Port", text: $port, error: portError, field: .port)
                        .keyboardType(.numberPad)
                }
            }
            .navigationTitle(request.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { presentationMode.wrappedValue.dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(request.confirmTitle) { confirm() }
                }
            }
        }
        .onAppear {
            focusedField = request.fixedHost == nil && host.isEmpty ? .host : .user
        }
    }

    @ViewBuilder
    private func field(_ label: String, text: Binding<String>, error: String?, field: Field) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(label, text: text)
                .focused($focusedField, equals: field)
                .foregroundColor(Color("TextPrimary"))
                .submitLabel(field == .port ? .go : .next)
                .onSubmit {
                    switch field {
                    case .host: focusedField = .user
                    case .user: focusedField = .port
                    case .port: confirm()
                    }
                }
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
    }

    /// Validates and hands the details back. A blank required field leaves the
    /// sheet open rather than dismissing it and losing what was typed.
    private func confirm() {
        let trimmedHost = (request.fixedHost ?? host).trimmingCharacters(in: .whitespaces)
        let trimmedUser = user.trimmingCharacters(in: .whitespaces)

        hostError = trimmedHost.isEmpty ? "Enter a host" : nil
        // No default to fall back on: the login name is the remote account, and
        // guessing one only produces a confusing auth failure.
        userError = trimmedUser.isEmpty ? "Enter a username" : nil

        let resolvedPort = parsePort()
        guard hostError == nil, userError == nil, let resolvedPort else { return }

        SSHSessionStore.lastUser = trimmedUser
        onConfirm(trimmedHost, resolvedPort, trimmedUser)
        presentationMode.wrappedValue.dismiss()
    }

    /// Reads the port field, falling back to the default when it is blank or
    /// not a number. A number outside the valid range is a typo worth reporting
    /// rather than replacing, since dialling it can only fail.
    private func parsePort() -> Int? {
        let trimmed = port.trimmingCharacters(in: .whitespaces)
        guard let value = Int(trimmed) else {
            portError = nil
            return SSHDefaults.port
        }
        guard value >= 1, value <= SSHDefaults.maxPort else {
            portError = "Enter a port between 1 and \(SSHDefaults.maxPort)"
            return nil
        }
        portError = nil
        return value
    }
}

#endif
