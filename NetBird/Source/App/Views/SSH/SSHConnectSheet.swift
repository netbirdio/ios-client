//
//  SSHConnectSheet.swift
//  NetBird
//

import SwiftUI

#if os(iOS)

struct SSHConnectSheet: View {
    let networkExtensionAdapter: NetworkExtensionAdapter
    /// true  → launched from a NetBird peer: host is fixed, password hidden, NetBird auth hint shown.
    /// false → standalone: all fields editable, password visible.
    let isPeerContext: Bool
    let peerName: String?

    @State var host: String
    @State var port: String
    @State var user: String
    @State var password: String
    @State private var saveSession = false
    @State private var sessionName = ""
    @State private var activeViewModel: SSHSessionViewModel?

    @EnvironmentObject private var sessionStore: SSHSessionStore
    @EnvironmentObject private var activeSessionStore: SSHActiveSessionStore
    @Environment(\.presentationMode) private var presentationMode

    init(networkExtensionAdapter: NetworkExtensionAdapter,
         isPeerContext: Bool = false,
         peerName: String? = nil,
         host: String = "",
         port: Int = 22,
         user: String = "",
         password: String = "") {
        self.networkExtensionAdapter = networkExtensionAdapter
        self.isPeerContext = isPeerContext
        self.peerName = peerName
        _host = State(initialValue: host)
        _port = State(initialValue: String(port))
        _user = State(initialValue: user)
        _password = State(initialValue: password)
        _sessionName = State(initialValue: peerName ?? host)
    }

    var body: some View {
        NavigationView {
            Form {
                if isPeerContext {
                    peerContextSection
                } else {
                    standaloneSection
                }

                Section {
                    Toggle("Save session", isOn: $saveSession)
                    if saveSession {
                        TextField("Session name", text: $sessionName)
                            .autocorrectionDisabled()
                    }
                }

                Section {
                    Button(action: connect) {
                        HStack {
                            Spacer()
                            Text("Connect")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(connectDisabled)
                }
            }
            .navigationTitle(isPeerContext ? (peerName ?? "SSH") : "New SSH Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { presentationMode.wrappedValue.dismiss() }
                }
            }
        }
        .fullScreenCover(item: $activeViewModel) { vm in
            SSHTerminalView(viewModel: vm)
        }
    }

    // MARK: - Peer context (NetBird peer)

    @ViewBuilder
    private var peerContextSection: some View {
        Section {
            HStack {
                Label("Host", systemImage: "network")
                    .foregroundColor(.secondary)
                Spacer()
                Text(host)
                    .foregroundColor(.secondary)
                    .font(.system(.body, design: .monospaced))
            }
            TextField("Username", text: $user)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Password (leave empty if NetBird SSH is enabled)", text: $password)
        } footer: {
            Text("Leave password empty to use NetBird SSH (requires SSH to be enabled for this peer **and** your account added to SSH access in the NetBird dashboard). Otherwise enter a password for regular SSH.")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Standalone (any host, full credentials)

    @ViewBuilder
    private var standaloneSection: some View {
        Section(header: Text("Connection")) {
            TextField("Host / IP", text: $host)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            HStack {
                Text("Port")
                Spacer()
                TextField("22", text: $port)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
            }
            TextField("Username", text: $user)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Password (optional for NetBird peers)", text: $password)
        }
    }

    // MARK: - Helpers

    private var connectDisabled: Bool {
        isPeerContext ? user.isEmpty : (host.isEmpty || user.isEmpty)
    }

    private func connect() {
        if saveSession {
            let session = SavedSSHSession(
                name: sessionName.isEmpty ? (peerName ?? host) : sessionName,
                host: host,
                port: Int(port) ?? 22,
                user: user
            )
            sessionStore.add(session)
            if !password.isEmpty {
                SSHKeychainStore.save(password: password, for: session.id)
            }
        }
        let vm = SSHSessionViewModel(
            networkExtensionAdapter: networkExtensionAdapter,
            host: host,
            port: Int(port) ?? 22,
            user: user,
            password: password,
            isNetBirdPeer: isPeerContext && password.isEmpty
        )
        activeSessionStore.add(vm)
        activeViewModel = vm
    }
}

#endif
