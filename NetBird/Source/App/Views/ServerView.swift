//
//  ServerView.swift
//  NetBirdiOS
//
//  Created by Pascal Fischer on 12.10.23.
//

import SwiftUI

struct ServerView: View {
    
    @EnvironmentObject var viewModel: ViewModel
    @StateObject private var serverViewModel = ServerViewModel(configurationFilePath: Preferences.configFile(), deviceName: Device.getName())
    
    private let defaultManagementServerUrl = "https://api.netbird.io"
    private let addSymbol = "add-symbol"
    private let removeSymbol = "remove-symbol"
    
    @State private var showSetupKeyField = false
    @State private var symbolAsset = "add-symbol"
    
    // Input field bindings
    @State private var managementServerUrl = ""
    @State private var setupKey = ""
    
    // Enable / disable buttons after tapping
    @State private var isButtonDisabled = false
    
    @State private var isAddDeviceToggleDisabled = false
    
    @Environment(\.presentationMode) var presentationMode: Binding<PresentationMode>
    
    func enableUi() {
        isButtonDisabled = false
        isAddDeviceToggleDisabled = false
    }
    
    func disableUi() {
        isButtonDisabled = true
        isAddDeviceToggleDisabled = true
    }
    
    func clearErrors() {
        serverViewModel.clearErrorsFor(field: .all)
    }
    
    @ViewBuilder
    func buildServer() -> some View {
        VStack(alignment: .leading){
            Text("Server")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(Color("TextPrimary"))
            CustomTextField(placeholder: "https://example-api.domain.com:443", text: $managementServerUrl, secure: .constant(false), height: 48)
                .onChange(of: managementServerUrl) { _ in
                    serverViewModel.clearErrorsFor(field: .url)
                }
        }
        .padding(.top, UIScreen.main.bounds.height * 0.04)
    }
    
    @ViewBuilder
    func buildErrorMessage(errorMessage: String?) -> some View {
        if let message = errorMessage, !message.isEmpty {
            Text(message).foregroundColor(.red)
        }
    }
     
    @ViewBuilder
    func buildSetupKey() -> some View {
        VStack(alignment: .leading) {
            Text("\(Image(symbolAsset)) Add this device with a setup key")
                .font(.system(size: 12))
                .onTapGesture {
                    showSetupKeyField = !showSetupKeyField

                    if (showSetupKeyField) {
                        symbolAsset = removeSymbol
                    } else {
                        // clear setup key input when toggling visibility to invisible
                        setupKey = ""
                        symbolAsset = addSymbol
                        // clear errors as well
                        serverViewModel.clearErrorsFor(field: .setupKey)
                    }
                }
                .disabled(isAddDeviceToggleDisabled)
            if showSetupKeyField {
                CustomTextField(placeholder: "0EF79C2F-DEE1-419B-BFC8-1BF529332998", text: $setupKey, secure: .constant(false), height: 48)
                    .padding([.bottom, .top], 8)
                    .onChange(of: setupKey) { _ in
                        serverViewModel.clearErrorsFor(field: .setupKey)
                    }
                buildErrorMessage(errorMessage: serverViewModel.viewErrors.setupKeyError)
                JustifiedText(text: "Using setup keys for user devices is not recommended. SSO with MFA provides stronger security, proper user-device association, and periodic re-authentication.", font: .systemFont(ofSize: 16), color: UIColor(Color.accentColor))
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.clear)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(Color.accentColor, lineWidth: 1)
                            )
                    )
            }
        }
    }
    
    @ViewBuilder
    func buildChangeButton() -> some View {
        SolidButton(text: isButtonDisabled ? "Verifying..." : "Change") {
            hideKeyboard()
            
            // Change button won't do anything if both fields are empty.
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
            
            clearErrors()

            Task {
                // Allow UI state changes to propagate before starting async work
                await Task.yield()
                
                if !serverUrl.isEmpty && !key.isEmpty {
                    await serverViewModel.loginWithSetupKey(managementServerUrl: serverUrl, setupKey: key)
                } else if !serverUrl.isEmpty {
                    await serverViewModel.changeManagementServerAddress(managementServerUrl: serverUrl)
                }
            }
        }
        .disabled(isButtonDisabled)
    }
    
    @ViewBuilder
    func buildUseNetBirdButton() -> some View {
        Button {
            hideKeyboard()
            managementServerUrl = defaultManagementServerUrl

            let serverUrl = defaultManagementServerUrl
            let key = setupKey.trimmingCharacters(in: .whitespacesAndNewlines)
            
            clearErrors()

            Task {
                // Allow UI state changes to propagate before starting async work
                await Task.yield()
                
                if key.isEmpty {
                    await serverViewModel.changeManagementServerAddress(managementServerUrl: serverUrl)
                } else {
                    await serverViewModel.loginWithSetupKey(managementServerUrl: serverUrl, setupKey: key)
                }
            }
        } label: {
            Label("Use NetBird server", image: "icon-netbird-button")
                .font(.headline)
                .padding()
                .foregroundColor(Color.accentColor)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(Color.accentColor, lineWidth: 1)
                        )
                )
        }
        .disabled(isButtonDisabled)
    }
    
    var body: some View {
        ZStack {
            Color("BgPage")
                .edgesIgnoringSafeArea(.bottom)
            VStack(alignment: .leading, spacing: 16) {
                buildServer()
                buildErrorMessage(errorMessage: serverViewModel.viewErrors.urlError)
                buildErrorMessage(errorMessage: serverViewModel.viewErrors.generalError)
                buildErrorMessage(errorMessage: serverViewModel.viewErrors.ssoNotSupportedError)
                buildSetupKey()
                buildChangeButton()
                buildUseNetBirdButton()
                Spacer()
            }
            .padding([.leading, .trailing], UIScreen.main.bounds.width * 0.10)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            hideKeyboard()
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .navigationBarItems(leading: CustomBackButton(text: "Change Server", action: {
            presentationMode.wrappedValue.dismiss()
        }))
        .onChange(of: serverViewModel.viewErrors.ssoNotSupportedError) { error in
            if error != nil {
                showSetupKeyField = true
                symbolAsset = removeSymbol
            }
        }
        .onChange(of: serverViewModel.isOperationSuccessful) { success in
            if success {
                // This will close the view
                self.presentationMode.wrappedValue.dismiss()
                // This will display the dialog that the server was changed
                viewModel.showServerChangedInfo = true
            }
        }
        .onChange(of: serverViewModel.isUiEnabled) { isEnabled in
            if isEnabled {
                enableUi()
            } else {
                disableUi()
            }
        }
    }
}

#Preview {
    ServerView()
        .environmentObject(ViewModel())
}
