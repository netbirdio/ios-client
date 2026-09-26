//
//  AdvancedView.swift
//  NetBirdiOS
//
//  Created by Pascal Fischer on 01.08.23.
//

import SwiftUI

struct AdvancedView: View {
    @EnvironmentObject var viewModel: ViewModel

    /// `disableUpdateSettings` gates editing across the whole screen: the
    /// values stay readable, every control that would write is locked.
    private var editingDisabled: Bool {
        viewModel.mdmRestrictions.features.disableUpdateSettings
    }

    /// The policy carries a pre-shared key, so the local one is irrelevant -
    /// the field is replaced by a locked "Configured" row.
    private var pskManaged: Bool {
        viewModel.mdmRestrictions.mdm.preSharedKey
    }

    private var rosenpassLocked: Bool {
        viewModel.mdmRestrictions.mdm.rosenpassEnabled || editingDisabled
    }

    private var rosenpassPermissiveLocked: Bool {
        viewModel.mdmRestrictions.mdm.rosenpassPermissive || editingDisabled
    }

    var body: some View {
        Form {
            Section {
                if pskManaged || viewModel.presharedKeySecure {
                    // The stored key is not readable through the bridge, so
                    // show that one is set rather than an empty secure field.
                    HStack {
                        Text("Pre-shared key")
                        Spacer()
                        Text("Configured")
                            .foregroundColor(Color("TextSecondary"))
                        if pskManaged {
                            MDMManagedBadge()
                        }
                    }
                } else {
                    TextField("Pre-shared key", text: $viewModel.presharedKey)
                        .disableAutocorrection(true)
                        .autocapitalization(.none)
                        .onChange(of: viewModel.presharedKey) { value in
                            checkForValidPresharedKey(text: value)
                        }
                        .mdmLocked(editingDisabled)
                }

                if viewModel.showInvalidPresharedKeyAlert && !pskManaged {
                    Text("Invalid key")
                        .foregroundColor(.red)
                        .font(.footnote)
                }

                // With a policy-supplied key there is nothing to save or
                // remove - the engine uses the managed value either way.
                if !pskManaged {
                    Button(viewModel.presharedKeySecure ? "Remove" : "Save") {
                        if !viewModel.showInvalidPresharedKeyAlert {
                            if viewModel.presharedKeySecure {
                                viewModel.removePreSharedKey()
                            } else {
                                viewModel.updatePreSharedKey()
                            }
                        }
                    }
                    .mdmLocked(editingDisabled)
                }
            } header: {
                Text("Pre-shared Key")
            } footer: {
                if pskManaged || editingDisabled {
                    MDMManagedFooter()
                } else {
                    Text("You will only communicate with peers that use the same key.")
                }
            }

            Section {
                Toggle("Enable Rosenpass", isOn: $viewModel.rosenpassEnabled)
                    .toggleStyle(SwitchToggleStyle(tint: .accentColor))
                    .onChange(of: viewModel.rosenpassEnabled) { value in
                        if !value {
                            viewModel.rosenpassPermissive = false
                        }
                        viewModel.setRosenpassEnabled(enabled: value)
                    }
                    .mdmLocked(rosenpassLocked)

                Toggle("Permissive mode", isOn: $viewModel.rosenpassPermissive)
                    .toggleStyle(SwitchToggleStyle(tint: .accentColor))
                    .onChange(of: viewModel.rosenpassPermissive) { value in
                        if value {
                            viewModel.rosenpassEnabled = true
                        }
                        viewModel.setRosenpassPermissive(permissive: value)
                    }
                    .mdmLocked(rosenpassPermissiveLocked)
            } header: {
                Text("Rosenpass")
            } footer: {
                if rosenpassLocked || rosenpassPermissiveLocked {
                    MDMManagedFooter()
                }
            }

            Section {
                Toggle("Force relay connection", isOn: $viewModel.forceRelayConnection)
                    .toggleStyle(SwitchToggleStyle(tint: .accentColor))
                    .onChange(of: viewModel.forceRelayConnection) { value in
                        viewModel.setForcedRelayConnection(isEnabled: value)
                    }
                    .mdmLocked(editingDisabled)

                Toggle("Disable IPv6", isOn: $viewModel.disableIPv6)
                    .toggleStyle(SwitchToggleStyle(tint: .accentColor))
                    .onChange(of: viewModel.disableIPv6) { value in
                        viewModel.setDisableIPv6(disabled: value)
                    }
                    .mdmLocked(editingDisabled)
            } header: {
                Text("Network & Security")
            } footer: {
                if editingDisabled {
                    MDMManagedFooter()
                }
            }
        }
        .onAppear {
            viewModel.refreshMDMRestrictions()
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
