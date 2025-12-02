//
//  ServerView.swift
//  NetBirdiOS
//
//  Created by Pascal Fischer on 12.10.23.
//

import SwiftUI

struct ServerView: View {
    
    @EnvironmentObject var viewModel: ViewModel
    
    @State private var showSetupKeyField = false
    @State private var isVerifyingServer = false
    @State private var isVerifyingKey = false
    
    @Environment(\.presentationMode) var presentationMode: Binding<PresentationMode>
    
    var body: some View {
        ZStack {
            Color("BgPage")
                .edgesIgnoringSafeArea(.bottom)
            VStack (alignment: .leading){
                Text("Server")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(Color("TextPrimary"))
                    .padding(.top, UIScreen.main.bounds.height * 0.04)
                CustomTextField(placeholder: "https://example-api.domain.com:443", text: $viewModel.server, secure: .constant(false))
                    .padding(.top, 3)
                if viewModel.showInvalidServerAlert {
                    Text("Invalid server address").foregroundColor(.red)
                }
                if showSetupKeyField && !isVerifyingServer {
                    Text("Setup key")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(Color("TextPrimary"))
                    CustomTextField(placeholder: "Key", text: $viewModel.setupKey, secure: .constant(false))
                        .padding(.top, 3)
                    if viewModel.showInvalidSetupKeyHint {
                        Text("Invalid setup key").foregroundColor(.red)
                    }
                }
                SolidButton(text: isVerifyingServer || isVerifyingKey ? "Verifying..." : "Change") {
                    if viewModel.showInvalidServerAlert || viewModel.server.isEmpty || isVerifyingServer || isVerifyingKey {
                        return
                    }
                    if viewModel.setupKey == "" {
                        isVerifyingServer = true
                        viewModel.updateManagementURL(url: viewModel.server) { sso in
                            switch sso {
                            case .none:
                                viewModel.showInvalidServerAlert = true
                            case .some(true):
                                viewModel.showServerChangedInfo = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                    self.presentationMode.wrappedValue.dismiss()
                                    viewModel.server = ""
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                                        viewModel.showServerChangedInfo = false
                                    }
                                }
                            case .some(false):
                                showSetupKeyField = true
                            }
                            isVerifyingServer = false
                        }
                    } else {
                        isVerifyingKey = true
                        viewModel.setSetupKey(key: viewModel.setupKey) { error in
                            if error != nil {
                                viewModel.showInvalidSetupKeyAlert = true
                            } else {
                                self.presentationMode.wrappedValue.dismiss()
                                viewModel.showServerChangedInfo = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                                    viewModel.showServerChangedInfo = false
                                }
                                viewModel.setupKey = ""
                            }
                            isVerifyingKey = false
                        }
                    }
                    print("use custom server")
                }
                .padding(.top, 5)
                Button {
                    if !isVerifyingKey && !isVerifyingServer {
                        isVerifyingServer = true
                        viewModel.updateManagementURL(url: "https://api.netbird.io") { sso in
                            print("use netbird server")
                            if sso ?? false {
                                self.presentationMode.wrappedValue.dismiss()
                                viewModel.showServerChangedInfo = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                                    viewModel.showServerChangedInfo = false
                                }
                            } else {
                                showSetupKeyField = true
                            }
                            isVerifyingServer = false
                        }
                    }
                } label: {
                    Text("Use NetBird server")
                        .font(.headline)
                        .foregroundColor(Color.accentColor)
                        .padding()
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
                Spacer()
            }
            .padding([.leading, .trailing], UIScreen.main.bounds.width * 0.10)
            if viewModel.showInvalidSetupKeyAlert {
                Color.black.opacity(0.4)
                    .edgesIgnoringSafeArea(.all)
                    .onTapGesture {
                        viewModel.buttonLock = true
                        viewModel.showInvalidSetupKeyAlert = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            viewModel.buttonLock = false
                        }
                    }
                
                WrongSetupKeyAlert(viewModel: viewModel, isPresented: $viewModel.showInvalidSetupKeyAlert)
                    .frame(maxWidth: UIScreen.main.bounds.width * 0.9)
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .navigationBarItems(leading: CustomBackButton(text: "Change Server", action: {
            presentationMode.wrappedValue.dismiss()
        }))        
        .onTapGesture {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }
    
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
