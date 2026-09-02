//
//  AddProfileSheet.swift
//  NetBird
//

import SwiftUI

#if os(iOS)

struct AddProfileSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// Shared rather than a one-off read: a policy that arrives while this
    /// sheet is open must not leave the form showing - or submitting - a
    /// management URL the policy has since replaced.
    @EnvironmentObject var viewModel: ViewModel
    @StateObject private var addVM = AddProfileViewModel()

    @State private var profileName = ""
    @State private var managementServerUrl = ""
    @State private var setupKey = ""
    @State private var showSetupKeyField = false
    @State private var showNameValidationAlert = false

    var onCreated: (() -> Void)?

    private let defaultManagementServerUrl = "https://api.netbird.io"

    private var isNameValid: Bool {
        !profileName.isEmpty && profileName.range(of: "^[a-zA-Z0-9_-]+$", options: .regularExpression) != nil
    }

    var body: some View {
        NavigationView {
            List {
                // Profile name
                Section {
                    TextField("Profile name", text: $profileName)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .disabled(addVM.isLoading)
                } header: {
                    Text("Profile")
                } footer: {
                    if let error = addVM.profileError {
                        Text(error)
                            .foregroundColor(.red)
                    } else {
                        Text("Only letters, numbers, underscores and hyphens allowed")
                            .foregroundColor(Color("TextSecondary"))
                    }
                }

                // Server URL - an MDM-enforced URL is shown, not asked for.
                Section {
                    if viewModel.mdmRestrictions.mdm.managesManagementURL {
                    HStack {
                        Text(viewModel.mdmRestrictions.mdm.managementURL)
                            .foregroundColor(Color("TextSecondary"))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Spacer()
                        MDMManagedBadge()
                    }
                    } else {
                    TextField("https://api.netbird.io", text: $managementServerUrl)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .disabled(addVM.isLoading)
                        .onChange(of: managementServerUrl) { _ in
                            addVM.urlError = nil
                            addVM.generalError = nil
                            addVM.ssoNotSupportedError = nil
                        }
                    }
                    if let error = addVM.urlError {
                        Text(error).foregroundColor(.red).font(.footnote)
                    }
                    if let error = addVM.generalError {
                        Text(error).foregroundColor(.red).font(.footnote)
                    }
                } header: {
                    Text("Server")
                } footer: {
                    if viewModel.mdmRestrictions.mdm.managesManagementURL {
                        MDMManagedFooter()
                    }
                }

                // Setup key (optional)
                Section {
                    DisclosureGroup("Add this device with a setup key", isExpanded: $showSetupKeyField) {
                        TextField("0EF79C2F-DEE1-419B-BFC8-1BF529332998", text: $setupKey)
                            .disableAutocorrection(true)
                            .autocapitalization(.allCharacters)
                            .disabled(addVM.isLoading)
                            .onChange(of: setupKey) { _ in
                                addVM.setupKeyError = nil
                            }
                        if let error = addVM.setupKeyError {
                            Text(error).foregroundColor(.red).font(.footnote)
                        }
                        if let error = addVM.ssoNotSupportedError {
                            Text(error).foregroundColor(.red).font(.footnote)
                        }
                        Text("Using setup keys for user devices is not recommended. SSO with MFA provides stronger security, proper user-device association, and periodic re-authentication.")
                            .font(.footnote)
                            .foregroundColor(.accentColor)
                            .padding(.vertical, 4)
                    }
                }
                .onChange(of: showSetupKeyField) { expanded in
                    if !expanded {
                        setupKey = ""
                        addVM.setupKeyError = nil
                    }
                }

                // Use NetBird server shortcut
                if !viewModel.mdmRestrictions.mdm.managesManagementURL {
                Section {
                    Button {
                        managementServerUrl = defaultManagementServerUrl
                    } label: {
                        HStack {
                            Spacer()
                            Image("icon-netbird-button")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 22, height: 22)
                            Text("Use NetBird server")
                            Spacer()
                        }
                    }
                    .disabled(addVM.isLoading)
                }
                }
            }
            .onAppear {
                viewModel.refreshMDMRestrictions()
            }
            .listStyle(.insetGrouped)
            .navigationTitle("New Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundColor(.accentColor)
                    .disabled(addVM.isLoading)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if addVM.isLoading {
                        ProgressView()
                    } else {
                        Button("Create") {
                            guard isNameValid else {
                                showNameValidationAlert = true
                                return
                            }
                            addVM.create(
                                name: profileName,
                                // Go overrides this anyway; submitting the
                                // enforced value keeps a stale local one from
                                // reaching the reachability check at all.
                                serverUrl: viewModel.mdmRestrictions.mdm.managesManagementURL
                                    ? viewModel.mdmRestrictions.mdm.managementURL
                                    : managementServerUrl,
                                setupKey: setupKey
                            )
                        }
                        .foregroundColor(.accentColor)
                    }
                }
            }
            .alert("Invalid Profile Name", isPresented: $showNameValidationAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Only letters, numbers, underscores and hyphens are allowed.")
            }
            .onChange(of: addVM.ssoNotSupportedError) { error in
                if error != nil {
                    showSetupKeyField = true
                }
            }
            .onChange(of: addVM.isSuccess) { success in
                if success {
                    onCreated?()
                    dismiss()
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

#Preview {
    AddProfileSheet()
        .environmentObject(ViewModel())
}

#endif
