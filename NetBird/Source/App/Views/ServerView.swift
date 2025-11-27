//
//  ServerView.swift
//  NetBirdiOS
//
//  Created by Pascal Fischer on 12.10.23.
//

import SwiftUI

struct ServerView: View {
    
    @EnvironmentObject var viewModel: ViewModel
    
    private let defaultManagementServerUrl = "https://api.netbird.io"
    
    @State private var showSetupKeyField = false
//    @State private var isVerifyingServer = false
//    @State private var isVerifyingKey = false
    @State private var symbolAsset = "add-symbol"
    @State private var managementServerUrl = ""
    @State private var setupKey = ""
    @State private var serverErrorMessage : String?
    
    @StateObject private var serverViewModel = ServerViewModel(configurationFilePath: Preferences.configFile(), deviceName: Device.getName())
    
    @Environment(\.presentationMode) var presentationMode: Binding<PresentationMode>
    
    func buildServer() -> some View {
        VStack(alignment: .leading){
            Text("Server")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(Color("TextPrimary"))
            CustomTextField(placeholder: "https://example-api.domain.com:443", text: $managementServerUrl, secure: .constant(false), height: 48)
                .onChange(of: managementServerUrl) { newText in
                    if serverErrorMessage != nil {
                        serverErrorMessage = nil
                    }
                }
        }
        .padding(.top, UIScreen.main.bounds.height * 0.04)
    }
    
    func buildServerErrorMessage() -> some View {
        VStack(alignment: .leading) {
            if serverErrorMessage != nil && !serverErrorMessage!.isEmpty {
                Text(serverErrorMessage!).foregroundColor(.red)
            }
        }
    }
    
    func buildSetupKey() -> some View {
        VStack(alignment: .leading) {
            Text("\(Image(symbolAsset)) Add this device with a setup key")
                .font(.system(size: 12))
                .onTapGesture {
                    showSetupKeyField = !showSetupKeyField

                    if (showSetupKeyField) {
                        symbolAsset = "remove-symbol"
                    } else {
                        // clear setup key input when toggling visibility to invisible
                        setupKey = ""
                        symbolAsset = "add-symbol"
                    }
                }
            if showSetupKeyField {
                Text("Setup key")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(Color("TextPrimary"))
                    .padding(.top, 8)
                CustomTextField(placeholder: "0EF79C2F-DEE1-419B-BFC8-1BF529332998", text: $setupKey, secure: .constant(false), height: 48)
                    .padding(.bottom, 8)
                Text("Using setup keys for user devices is not recommended. SSO with MFA provides stronger security, proper user-device association, and periodic re-authentication.")
                    .font(.system(size: 16))
                    .padding()
                    .foregroundColor(Color.accentColor)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(red: 0, green: 0, blue: 0, opacity: 0))
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(Color.accentColor, lineWidth: 1)
                            )
                    )
//                if viewModel.showInvalidSetupKeyHint {
//                    Text("Invalid setup key").foregroundColor(.red)
//                }
            }
        }
    }
    
    func buildChangeButton() -> some View {
        // isVerifyingServer || isVerifyingKey ? "Verifying..." :
        SolidButton(text: "Change") {
//            if viewModel.showInvalidServerAlert || viewModel.server.isEmpty || isVerifyingServer || isVerifyingKey {
//                return
//            }
//            if viewModel.setupKey == "" {
//                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
//                    isVerifyingServer = true
//                }
//                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
//                    let sso = viewModel.updateManagementURL(url: viewModel.server)
//                    switch sso {
//                    case .none:
//                        viewModel.showInvalidServerAlert = true
//                    case .some(true):
//                        viewModel.showServerChangedInfo = true
//                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
//                            self.presentationMode.wrappedValue.dismiss()
//                            viewModel.server = ""
//                            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
//                                viewModel.showServerChangedInfo = false
//                            }
//                        }
//                    case .some(false):
//                        showSetupKeyField = true
//                    }
//                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
//                        isVerifyingServer = false
//                    }
//                }
//            } else {
//                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
//                    isVerifyingKey = true
//                }
//                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
//                    do {
//                        try viewModel.setSetupKey(key: viewModel.setupKey)
//                        self.presentationMode.wrappedValue.dismiss()
//                        viewModel.showServerChangedInfo = true
//                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
//                            viewModel.showServerChangedInfo = false
//                        }
//                        viewModel.setupKey = ""
//                        isVerifyingKey = false
//                    } catch {
//                        viewModel.showInvalidSetupKeyAlert = true
//                        isVerifyingKey = false
//                    }
//                }
//            }
//            print("use custom server")
            hideKeyboard()
            
//            if serverErrorMessage != nil {
//                return
//            }
            
            if managementServerUrl.isEmpty && setupKey.isEmpty {
                return
            }
            
            if !managementServerUrl.isEmpty && !setupKey.isEmpty {
                serverViewModel.loginWithSetupKey(managementServerUrl: managementServerUrl, setupKey: setupKey)
            } else if !managementServerUrl.isEmpty {
                serverViewModel.changeManagementServerAddress(managementServerUrl: managementServerUrl)
            } else {
                managementServerUrl = defaultManagementServerUrl
                
                serverViewModel.loginWithSetupKey(managementServerUrl: managementServerUrl, setupKey: setupKey)
            }
        }
    }
    
    func buildUseNetBirdButton() -> some View {
        Button {
//            if !isVerifyingKey && !isVerifyingServer {
//                let sso = viewModel.updateManagementURL(url: "https://api.netbird.io")
//                print("use netbird server")
//                if sso ?? false {
//                    self.presentationMode.wrappedValue.dismiss()
//                    viewModel.showServerChangedInfo = true
//                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
//                        viewModel.showServerChangedInfo = false
//                    }
//                } else {
//                    showSetupKeyField = true
//                }
//            }
            hideKeyboard()
            managementServerUrl = defaultManagementServerUrl
            
            if setupKey.isEmpty {
                serverViewModel.changeManagementServerAddress(managementServerUrl: managementServerUrl)
            } else {
                serverViewModel.loginWithSetupKey(managementServerUrl: managementServerUrl, setupKey: setupKey)
            }
        } label: {
            Label("Use NetBird server", image: "icon-netbird-button")
                .font(.headline)
                .padding()
                .foregroundColor(Color.accentColor)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(red: 0, green: 0, blue: 0, opacity: 0))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(Color.accentColor, lineWidth: 1)
                        )
                )
        }
    }
    
    var body: some View {
        ZStack {
            Color("BgPage")
                .edgesIgnoringSafeArea(.bottom)
                .onTapGesture {
                    hideKeyboard()
                }
            VStack(alignment: .leading, spacing: 16) {
                buildServer()
                buildServerErrorMessage()
                buildSetupKey()
                buildChangeButton()
                buildUseNetBirdButton()
                Spacer()
            }
            .padding([.leading, .trailing], UIScreen.main.bounds.width * 0.10)
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .navigationBarItems(leading: CustomBackButton(text: "Change Server", action: {
            presentationMode.wrappedValue.dismiss()
        }))
//        .onTapGesture {
//            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
//        }
        .onChange(of: serverViewModel.isOperationSuccessful) { success in
            if success {
                self.presentationMode.wrappedValue.dismiss()
                viewModel.showServerChangedInfo = true
            }
        }
        .onChange(of: serverViewModel.errorMessage) { error in
            if error != nil && !error!.isEmpty {
                // show error alert
                serverErrorMessage = error
            } else {
                // clear error alert
                serverErrorMessage = nil
            }
        }
    }
    
//    var body: some View {
//        ZStack {
//            Color("BgPage")
//                .edgesIgnoringSafeArea(.bottom)
//            VStack (alignment: .leading, spacing: 16){
//                Text("Server")
//                    .font(.system(size: 18, weight: .bold))
//                    .foregroundColor(Color("TextPrimary"))
//                    .padding(.top, UIScreen.main.bounds.height * 0.04)
//                CustomTextField(placeholder: "https://example-api.domain.com:443", text: $viewModel.server, secure: .constant(false))
//                    .padding(.top, 3)
//                if viewModel.showInvalidServerAlert {
//                    Text("Invalid server address").foregroundColor(.red)
//                }
//                Text("\(Image(symbolAsset)) Add this device with a setup key")
//                    .font(.system(size: 12))
//                    .padding(.top, 3)
//                    .onTapGesture {
//                        showSetupKeyField = !showSetupKeyField
//                        
//                        if (showSetupKeyField) {
//                            symbolAsset = "remove-symbol"
//                        } else {
//                            symbolAsset = "add-symbol"
//                        }
//                    }
//                if showSetupKeyField {
//                    Text("Setup key")
//                        .font(.system(size: 18, weight: .bold))
//                        .foregroundColor(Color("TextPrimary"))
//                    CustomTextField(placeholder: "0EF79C2F-DEE1-419B-BFC8-1BF529332998", text: $viewModel.setupKey, secure: .constant(false))
//                        .padding(.top, 3)
//                    Text("Using setup keys for user devices is not recommended. SSO with MFA provides stronger security, proper user-device association, and periodic re-authentication.")
//                        .padding()
//                        .font(.system(size: 16))
//                        .foregroundColor(Color.accentColor)
//                        .frame(maxWidth: .infinity)
//                        .multilineTextAlignment(.center)
//                        .background(
//                            RoundedRectangle(cornerRadius: 3)
//                                .fill(Color(red: 0, green: 0, blue: 0, opacity: 0))
//                                .overlay(
//                                    RoundedRectangle(cornerRadius: 3)
//                                        .stroke(Color.accentColor, lineWidth: 1)
//                                )
//                        )
//                    if viewModel.showInvalidSetupKeyHint {
//                        Text("Invalid setup key").foregroundColor(.red)
//                    }
//                }
//                SolidButton(text: isVerifyingServer || isVerifyingKey ? "Verifying..." : "Change") {
//                    if viewModel.showInvalidServerAlert || viewModel.server.isEmpty || isVerifyingServer || isVerifyingKey {
//                        return
//                    }
//                    if viewModel.setupKey == "" {
//                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
//                            isVerifyingServer = true
//                        }
//                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
//                            let sso = viewModel.updateManagementURL(url: viewModel.server)
//                            switch sso {
//                            case .none:
//                                viewModel.showInvalidServerAlert = true
//                            case .some(true):
//                                viewModel.showServerChangedInfo = true
//                                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
//                                    self.presentationMode.wrappedValue.dismiss()
//                                    viewModel.server = ""
//                                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
//                                        viewModel.showServerChangedInfo = false
//                                    }
//                                }
//                            case .some(false):
//                                showSetupKeyField = true
//                            }
//                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
//                                isVerifyingServer = false
//                            }
//                        }
//                    } else {
//                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
//                            isVerifyingKey = true
//                        }
//                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
//                            do {
//                                try viewModel.setSetupKey(key: viewModel.setupKey)
//                                self.presentationMode.wrappedValue.dismiss()
//                                viewModel.showServerChangedInfo = true
//                                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
//                                    viewModel.showServerChangedInfo = false
//                                }
//                                viewModel.setupKey = ""
//                                isVerifyingKey = false
//                            } catch {
//                                viewModel.showInvalidSetupKeyAlert = true
//                                isVerifyingKey = false
//                            }
//                        }
//                    }
//                    print("use custom server")
//                }
//                .padding(.top, 5)
//                Button {
//                    if !isVerifyingKey && !isVerifyingServer {
//                        let sso = viewModel.updateManagementURL(url: "https://api.netbird.io")
//                        print("use netbird server")
//                        if sso ?? false {
//                            self.presentationMode.wrappedValue.dismiss()
//                            viewModel.showServerChangedInfo = true
//                            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
//                                viewModel.showServerChangedInfo = false
//                            }
//                        } else {
//                            showSetupKeyField = true
//                        }
//                    }
//                } label: {
//                    Label("Use NetBird server", image: "icon-netbird-button")
//                        .font(.headline)
//                        .foregroundColor(Color.accentColor)
//                        .padding()
//                        .frame(maxWidth: .infinity)
//                        .background(
//                            RoundedRectangle(cornerRadius: 3)
//                                .fill(Color(red: 0, green: 0, blue: 0, opacity: 0))
//                                .overlay(
//                                    RoundedRectangle(cornerRadius: 3)
//                                        .stroke(Color.accentColor, lineWidth: 1)
//                                )
//                        )
//                }
//                Spacer()
//            }
//            .padding([.leading, .trailing], UIScreen.main.bounds.width * 0.10)
//            if viewModel.showInvalidSetupKeyAlert {
//                Color.black.opacity(0.4)
//                    .edgesIgnoringSafeArea(.all)
//                    .onTapGesture {
//                        viewModel.buttonLock = true
//                        viewModel.showInvalidSetupKeyAlert = false
//                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
//                            viewModel.buttonLock = false
//                        }
//                    }
//                
//                WrongSetupKeyAlert(viewModel: viewModel, isPresented: $viewModel.showInvalidSetupKeyAlert)
//                    .frame(maxWidth: UIScreen.main.bounds.width * 0.9)
//            }
//        }
//        .navigationViewStyle(StackNavigationViewStyle())
//        .navigationBarTitleDisplayMode(.inline)
//        .navigationBarBackButtonHidden(true)
//        .navigationBarItems(leading: CustomBackButton(text: "Change Server", action: {
//            presentationMode.wrappedValue.dismiss()
//        }))        
//        .onTapGesture {
//            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
//        }
//    }
}

struct WrongSetupKeyAlert: View {
    @StateObject var viewModel: ViewModel
    @Binding var isPresented: Bool
    
    var body: some View {
        VStack(spacing: 20) {
            Image("exclamation-circle")
                .padding(.top, 20)
            Text("Setup key invalid")
                .font(.title)
                .foregroundColor(Color("TextAlert"))
            Text("The provided setup could not be used to login. Check if the key is correct.")
                .foregroundColor(Color("TextAlert"))
                .multilineTextAlignment(.center)
            SolidButton(text: "Confirm") {
                isPresented.toggle()
            }
            .padding(.top, 20)
        }
        .padding()
        .background(Color("BgSideDrawer"))
        .cornerRadius(15)
        .shadow(radius: 10)
    }
}

#Preview {
    ServerView()
}
