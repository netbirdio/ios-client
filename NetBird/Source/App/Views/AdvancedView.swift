//
//  AdvancedView.swift
//  NetBirdiOS
//
//  Created by Pascal Fischer on 01.08.23.
//

import SwiftUI

struct AdvancedView: View {
    @EnvironmentObject var viewModel: ViewModel

    var body: some View {
        Form {
            Section {
                if viewModel.presharedKeySecure {
                    SecureField("Pre-shared key", text: $viewModel.presharedKey)
                        .disabled(true)
                } else {
                    TextField("Pre-shared key", text: $viewModel.presharedKey)
                        .disableAutocorrection(true)
                        .autocapitalization(.none)
                        .onChange(of: viewModel.presharedKey) { value in
                            checkForValidPresharedKey(text: value)
                        }
                }

                if viewModel.showInvalidPresharedKeyAlert {
                    Text("Invalid key")
                        .foregroundColor(.red)
                        .font(.footnote)
                }

                Button(viewModel.presharedKeySecure ? "Remove" : "Save") {
                    if !viewModel.showInvalidPresharedKeyAlert {
                        if viewModel.presharedKeySecure {
                            viewModel.removePreSharedKey()
                        } else {
                            viewModel.updatePreSharedKey()
                        }
                    }
                }
            } header: {
                Text("Pre-shared Key")
            } footer: {
                Text("You will only communicate with peers that use the same key.")
            }

            Section(header: Text("Rosenpass")) {
                Toggle("Enable Rosenpass", isOn: $viewModel.rosenpassEnabled)
                    .toggleStyle(SwitchToggleStyle(tint: .accentColor))
                    .onChange(of: viewModel.rosenpassEnabled) { value in
                        if !value {
                            viewModel.rosenpassPermissive = false
                        }
                        viewModel.setRosenpassEnabled(enabled: value)
                    }

                Toggle("Permissive mode", isOn: $viewModel.rosenpassPermissive)
                    .toggleStyle(SwitchToggleStyle(tint: .accentColor))
                    .onChange(of: viewModel.rosenpassPermissive) { value in
                        if value {
                            viewModel.rosenpassEnabled = true
                        }
                        viewModel.setRosenpassPermissive(permissive: value)
                    }
            }

            Section(header: Text("Network & Security")) {
                Toggle("Force relay connection", isOn: $viewModel.forceRelayConnection)
                    .toggleStyle(SwitchToggleStyle(tint: .accentColor))
                    .onChange(of: viewModel.forceRelayConnection) { value in
                        viewModel.setForcedRelayConnection(isEnabled: value)
                    }

                Toggle("Disable IPv6", isOn: $viewModel.disableIPv6)
                    .toggleStyle(SwitchToggleStyle(tint: .accentColor))
                    .onChange(of: viewModel.disableIPv6) { value in
                        viewModel.setDisableIPv6(disabled: value)
                    }
            }
        }
        .onAppear {
            viewModel.loadRosenpassSettings()
            viewModel.loadPreSharedKey()
            viewModel.loadIPv6Settings()
        }
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
        .alert(isPresented: $viewModel.showForceRelayAlert) {
            Alert(
                title: Text("Force Relay"),
                message: Text("To apply the setting, you will need to reconnect."),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    func checkForValidPresharedKey(text: String) {
        if isValidBase64EncodedString(text) {
            viewModel.showInvalidPresharedKeyAlert = false
        } else {
            viewModel.showInvalidPresharedKeyAlert = true
        }
    }

    func isValidBase64EncodedString(_ input: String) -> Bool {
        if input.isEmpty {
            return true
        }
        guard let data = Data(base64Encoded: input) else {
            return false
        }
        return data.count == 32
    }
}

struct AdvancedView_Previews: PreviewProvider {
    static var previews: some View {
        AdvancedView()
    }
}
