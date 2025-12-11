//
//  TVServerView.swift
//  NetBird
//
//  Server configuration view for tvOS.
//
//  Allows users to change the management server URL and optionally
//  use a setup key for registration.
//
//  Key differences from iOS ServerView:
//  - No keyboard (uses tvOS text input via Siri Remote)
//  - Larger text and buttons for "10-foot experience"
//  - Focus-based navigation
//

import SwiftUI
import NetBirdSDK

#if os(tvOS)

struct TVServerView: View {
    @EnvironmentObject var viewModel: ViewModel
    @Binding var isPresented: Bool

    @StateObject private var serverViewModel = ServerViewModel(
        configurationFilePath: Preferences.configFile(),
        deviceName: Device.getName()
    )

    private let defaultManagementServerUrl = "https://api.netbird.io"

    // Input field values
    @State private var managementServerUrl = ""
    @State private var setupKey = ""
    @State private var showSetupKeyField = false

    // Focus states
    @FocusState private var focusedField: FocusedField?

    enum FocusedField {
        case serverUrl
        case setupKey
        case changeButton
        case useNetBirdButton
        case cancelButton
        case showSetupKeyToggle
    }

    var body: some View {
        ZStack {
            // Background
            TVColors.bgMenu
                .ignoresSafeArea()

            HStack(spacing: 60) {
                // Left Side - Form
                VStack(alignment: .leading, spacing: 30) {
                    // Header
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Change Server")
                            .font(.system(size: 48, weight: .bold))
                            .foregroundColor(TVColors.textPrimary)

                        Text("Configure the management server for your NetBird connection")
                            .font(.system(size: 24))
                            .foregroundColor(TVColors.textSecondary)
                    }
                    .padding(.bottom, 20)

                    // Server URL field
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Server URL")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundColor(TVColors.textPrimary)

                        TextField("", text: $managementServerUrl, prompt: nil)
                            .textFieldStyle(.plain)
                            .font(.system(size: 28))
                            .padding(20)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(TVColors.bgPrimary)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(focusedField == .serverUrl ? Color.accentColor : Color.clear, lineWidth: 3)
                            )
                            .focused($focusedField, equals: .serverUrl)
                            .onChange(of: managementServerUrl) {
                                serverViewModel.clearErrorsFor(field: .url)
                            }

                        // Error messages
                        if let error = serverViewModel.viewErrors.urlError {
                            Text(error)
                                .font(.system(size: 20))
                                .foregroundColor(.red)
                        }
                        if let error = serverViewModel.viewErrors.generalError {
                            Text(error)
                                .font(.system(size: 20))
                                .foregroundColor(.red)
                        }
                    }

                    // SSO not supported message
                    if let ssoError = serverViewModel.viewErrors.ssoNotSupportedError {
                        Text(ssoError)
                            .font(.system(size: 20))
                            .foregroundColor(.orange)
                            .padding()
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.orange.opacity(0.1))
                            )
                    }

                    // Setup key toggle
                    Button(action: {
                        showSetupKeyField.toggle()
                        if !showSetupKeyField {
                            setupKey = ""
                            serverViewModel.clearErrorsFor(field: .setupKey)
                        }
                    }) {
                        HStack(spacing: 15) {
                            Image(systemName: showSetupKeyField ? "minus.circle.fill" : "plus.circle.fill")
                                .font(.system(size: 24))
                                .foregroundColor(.accentColor)

                            Text("Add this device with a setup key")
                                .font(.system(size: 22))
                                .foregroundColor(focusedField == .showSetupKeyToggle ? .white : TVColors.textPrimary)
                        }
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .focused($focusedField, equals: .showSetupKeyToggle)
                    .disabled(!serverViewModel.isUiEnabled)

                    // Setup key field (conditional)
                    if showSetupKeyField {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Setup Key")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundColor(TVColors.textPrimary)

                            TextField("0EF79C2F-DEE1-419B-BFC8-1BF529332998", text: $setupKey)
                                .textFieldStyle(.plain)
                                .font(.system(size: 24, design: .monospaced))
                                .padding(20)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(TVColors.bgPrimary)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(focusedField == .setupKey ? Color.accentColor : Color.clear, lineWidth: 3)
                                )
                                .focused($focusedField, equals: .setupKey)
                                .onChange(of: setupKey) {
                                    serverViewModel.clearErrorsFor(field: .setupKey)
                                }

                            if let error = serverViewModel.viewErrors.setupKeyError {
                                Text(error)
                                    .font(.system(size: 20))
                                    .foregroundColor(.red)
                            }

                            // Warning about setup keys
                            Text("Using setup keys for user devices is not recommended. SSO with MFA provides stronger security.")
                                .font(.system(size: 18))
                                .foregroundColor(.accentColor)
                                .padding()
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.accentColor, lineWidth: 1)
                                )
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    Spacer()

                    // Action buttons
                    HStack(spacing: 30) {
                        // Cancel button
                        Button(action: {
                            isPresented = false
                        }) {
                            Text("Cancel")
                                .font(.system(size: 24))
                                .foregroundColor(.white)
                                .padding(.horizontal, 50)
                                .padding(.vertical, 18)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color.white.opacity(0.5), lineWidth: 2)
                                )
                        }
                        .buttonStyle(.plain)
                        .focused($focusedField, equals: .cancelButton)

                        // Use NetBird button
                        Button(action: useNetBirdServer) {
                            HStack(spacing: 12) {
                                Image("icon-netbird-button")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 28, height: 28)

                                Text("Use NetBird")
                                    .font(.system(size: 24))
                            }
                            .foregroundColor(.accentColor)
                            .padding(.horizontal, 40)
                            .padding(.vertical, 18)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.accentColor, lineWidth: 2)
                            )
                        }
                        .buttonStyle(.plain)
                        .focused($focusedField, equals: .useNetBirdButton)
                        .disabled(!serverViewModel.isUiEnabled)

                        // Change button
                        Button(action: changeServer) {
                            Group {
                                if !serverViewModel.isUiEnabled {
                                    HStack(spacing: 10) {
                                        ProgressView()
                                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                        Text("Validating...")
                                    }
                                } else {
                                    Text("Change")
                                }
                            }
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 50)
                            .padding(.vertical, 18)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.accentColor)
                            )
                        }
                        .buttonStyle(.plain)
                        .focused($focusedField, equals: .changeButton)
                        .disabled(!serverViewModel.isUiEnabled)
                    }
                }
                .padding(60)
                .frame(maxWidth: .infinity, alignment: .leading)

                // Right Side - Info panel
                VStack(alignment: .leading, spacing: 30) {
                    Image("netbird-logo-menu")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 200)
                        .opacity(0.5)

                    Spacer()

                    VStack(alignment: .leading, spacing: 20) {
                        InfoRow(icon: "checkmark.shield.fill", text: "Self-hosted servers supported")
                        InfoRow(icon: "lock.fill", text: "Secure WireGuard connection")
                        InfoRow(icon: "person.2.fill", text: "SSO authentication preferred")
                    }

                    Spacer()

                    Text("docs.netbird.io")
                        .font(.system(size: 20))
                        .foregroundColor(TVColors.textSecondary.opacity(0.6))
                }
                .padding(50)
                .frame(width: 400)
                .background(TVColors.bgPrimary.opacity(0.3))
            }
        }
        .onAppear {
            focusedField = .serverUrl
            loadCurrentServerUrl()
        }
        .onChange(of: serverViewModel.viewErrors.ssoNotSupportedError) { _, newValue in
            if newValue != nil {
                showSetupKeyField = true
            }
        }
        .onChange(of: serverViewModel.isOperationSuccessful) { _, newValue in
            if newValue {
                viewModel.showServerChangedInfo = true
                isPresented = false
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showSetupKeyField)
    }

    // MARK: - Actions

    private func changeServer() {
        let trimmedUrl = managementServerUrl.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let trimmedKey = setupKey.trimmingCharacters(in: .whitespacesAndNewlines)

        // Nothing to do if both empty
        guard !trimmedUrl.isEmpty || !trimmedKey.isEmpty else { return }

        var serverUrl = trimmedUrl
        if serverUrl.isEmpty {
            serverUrl = defaultManagementServerUrl
        }
        managementServerUrl = serverUrl

        serverViewModel.clearErrorsFor(field: .all)

        Task {
            await Task.yield()

            if !serverUrl.isEmpty && !trimmedKey.isEmpty {
                await serverViewModel.loginWithSetupKey(managementServerUrl: serverUrl, setupKey: trimmedKey)
            } else if !serverUrl.isEmpty {
                await serverViewModel.changeManagementServerAddress(managementServerUrl: serverUrl)
            }
        }
    }

    private func useNetBirdServer() {
        managementServerUrl = defaultManagementServerUrl

        let trimmedKey = setupKey.trimmingCharacters(in: .whitespacesAndNewlines)

        serverViewModel.clearErrorsFor(field: .all)

        Task {
            await Task.yield()

            if trimmedKey.isEmpty {
                await serverViewModel.changeManagementServerAddress(managementServerUrl: defaultManagementServerUrl)
            } else {
                await serverViewModel.loginWithSetupKey(managementServerUrl: defaultManagementServerUrl, setupKey: trimmedKey)
            }
        }
    }

    private func loadCurrentServerUrl() {
        // Leave the text field empty by default - user will enter their own URL
        managementServerUrl = ""
    }
}

// Helper view for info rows
private struct InfoRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 15) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundColor(.accentColor)
                .frame(width: 30)

            Text(text)
                .font(.system(size: 22))
                .foregroundColor(TVColors.textSecondary)
        }
    }
}

struct TVServerView_Previews: PreviewProvider {
    static var previews: some View {
        TVServerView(isPresented: .constant(true))
            .environmentObject(ViewModel())
    }
}

#endif
