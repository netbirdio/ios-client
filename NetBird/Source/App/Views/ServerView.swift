//
//  ServerView.swift
//  NetBirdiOS
//
//  Created by Pascal Fischer on 12.10.23.
//

import SwiftUI

struct ServerView: View {
    @EnvironmentObject var viewModel: ViewModel
    @StateObject private var serverViewModel = ServerViewModel(configurationFilePath: Preferences.configFile() ?? "", deviceName: Device.getName())

    private let defaultManagementServerUrl = "https://api.netbird.io"

    @State private var showSetupKeyField = false
    @State private var managementServerUrl = ""
    @State private var setupKey = ""
    @State private var isButtonDisabled = false
    @State private var isAddDeviceToggleDisabled = false

    @Environment(\.presentationMode) var presentationMode: Binding<PresentationMode>

    var body: some View {
        Form {
            Section(header: Text("Server")) {
                ZStack(alignment: .leading) {
                    TextField("https://example-api.domain.com:443", text: $managementServerUrl)
                        .foregroundColor(Color("TextPrimary"))
                        .disableAutocorrection(true)
                        .autocapitalization(.none)
                        .keyboardType(.URL)
                }
                    .onChange(of: managementServerUrl) { _ in
                        serverViewModel.clearErrorsFor(field: .url)
                    }

                if let error = serverViewModel.viewErrors.urlError, !error.isEmpty {
                    Text(error).foregroundColor(.red).font(.footnote)
                }
                if let error = serverViewModel.viewErrors.generalError, !error.isEmpty {
                    Text(error).foregroundColor(.red).font(.footnote)
                }
            }

            Section {
                DisclosureGroup("Add this device with a setup key", isExpanded: $showSetupKeyField) {
                    TextField("0EF79C2F-DEE1-419B-BFC8-1BF529332998", text: $setupKey)
                        .disableAutocorrection(true)
                        .autocapitalization(.allCharacters)
                        .disabled(isAddDeviceToggleDisabled)
                        .onChange(of: setupKey) { _ in
                            serverViewModel.clearErrorsFor(field: .setupKey)
                        }

                    if let error = serverViewModel.viewErrors.setupKeyError, !error.isEmpty {
                        Text(error).foregroundColor(.red).font(.footnote)
                    }

                    if let error = serverViewModel.viewErrors.ssoNotSupportedError, !error.isEmpty {
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
                    serverViewModel.clearErrorsFor(field: .setupKey)
                }
            }

            Section {
                if isButtonDisabled {
                    HStack {
                        Spacer()
                        ProgressView()
                            .padding(.trailing, 8)
                        Text("Validating...")
                        Spacer()
                    }
                } else {
                    Button {
                        dismissKeyboard()
                        performChange()
                    } label: {
                        HStack {
                            Spacer()
                            Text("Change")
                            Spacer()
                        }
                    }
                }
            }

            Section {
                Button {
                    dismissKeyboard()
                    managementServerUrl = defaultManagementServerUrl
                    performUseNetBird()
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
                .disabled(isButtonDisabled)
            }
        }
        .navigationTitle("Change Server")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: serverViewModel.viewErrors.ssoNotSupportedError) { error in
            if error != nil {
                showSetupKeyField = true
            }
        }
        .onChange(of: serverViewModel.isOperationSuccessful) { success in
            if success {
                presentationMode.wrappedValue.dismiss()
                viewModel.showServerChangedInfo = true
            }
        }
        .onChange(of: serverViewModel.isUiEnabled) { isEnabled in
            if isEnabled {
                isButtonDisabled = false
                isAddDeviceToggleDisabled = false
            } else {
                isButtonDisabled = true
                isAddDeviceToggleDisabled = true
            }
        }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func performChange() {
        if managementServerUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && setupKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }

        var serverUrl = managementServerUrl.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if serverUrl.isEmpty {
            serverUrl = defaultManagementServerUrl
        }
        managementServerUrl = serverUrl

        let key = setupKey.trimmingCharacters(in: .whitespacesAndNewlines)

        serverViewModel.clearErrorsFor(field: .all)

        Task {
            await Task.yield()
            if !serverUrl.isEmpty && !key.isEmpty {
                await serverViewModel.loginWithSetupKey(managementServerUrl: serverUrl, setupKey: key)
            } else if !serverUrl.isEmpty {
                await serverViewModel.changeManagementServerAddress(managementServerUrl: serverUrl)
            }
        }
    }

    private func performUseNetBird() {
        let serverUrl = defaultManagementServerUrl
        let key = setupKey.trimmingCharacters(in: .whitespacesAndNewlines)

        serverViewModel.clearErrorsFor(field: .all)

        Task {
            await Task.yield()
            if key.isEmpty {
                await serverViewModel.changeManagementServerAddress(managementServerUrl: serverUrl)
            } else {
                await serverViewModel.loginWithSetupKey(managementServerUrl: serverUrl, setupKey: key)
            }
        }
    }
}

#Preview {
    ServerView()
        .environmentObject(ViewModel())
}
