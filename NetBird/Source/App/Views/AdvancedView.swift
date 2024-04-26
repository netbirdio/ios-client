//
//  AdvancedView.swift
//  NetBirdiOS
//
//  Created by Pascal Fischer on 01.08.23.
//

import SwiftUI

struct AdvancedView: View {
    @EnvironmentObject var viewModel: ViewModel
    @Environment(\.presentationMode) var presentationMode: Binding<PresentationMode>
        
    var body: some View {
        ZStack {
            Color("BgPage")
                .edgesIgnoringSafeArea(.bottom)
            VStack (alignment: .leading){
                Text("Add a pre-shared key")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(Color("TextPrimary"))
                    .padding(.top, UIScreen.main.bounds.height * 0.04)
                Text("You will only communicate with peers that use the same key.")
                    .multilineTextAlignment(.leading)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundColor(Color("TextSecondary"))
                    .padding(.top, 3)
                CustomTextField(placeholder: "Add a pre-shared key", text: $viewModel.presharedKey, secure: $viewModel.presharedKeySecure)
                    .padding(.top, 3)
                    .onChange(of: viewModel.presharedKey, perform: { value in
                        checkForValidPresharedKey(text: value)
                    })
                if viewModel.showInvalidPresharedKeyAlert {
                    Text("Invalid key").foregroundColor(.red)
                }
                SolidButton(text: viewModel.presharedKeySecure ? "Remove" : "Save") {
                    if !viewModel.showInvalidPresharedKeyAlert {
                        if viewModel.presharedKeySecure {
                            viewModel.removePreSharedKey() // TODO: might replace this with new implememented removal
                        } else {
                            viewModel.updatePreSharedKey()
                            print("save preshared key")
                            self.presentationMode.wrappedValue.dismiss()
                        }
                    }
                }
                .padding(.top, 5)
                Divider()
                    .padding([.top, .bottom])
                Toggle(isOn: $viewModel.rosenpassEnabled, label: {
                    Text("Enable Rosenpass.")
                        .multilineTextAlignment(.leading)
                        .font(.system(size: 18, weight: .regular))
                        .foregroundColor(Color("TextSecondary"))
                        .padding(.top, 3)
                })
                .onChange(of: viewModel.rosenpassEnabled) { value in
                    if !value {
                        viewModel.rosenpassPermissive = false
                    }
                    viewModel.setRosenpassEnabled(enabled: value)
                }
                Toggle(isOn: $viewModel.rosenpassPermissive, label: {
                    Text("Enable Rosenpass permissive mode.")
                        .multilineTextAlignment(.leading)
                        .font(.system(size: 18, weight: .regular))
                        .foregroundColor(Color("TextSecondary"))
                        .padding(.top, 3)
                })
                .onChange(of: viewModel.rosenpassPermissive) { value in
                    if value {
                        viewModel.rosenpassEnabled = true
                    }
                    viewModel.setRosenpassPermissive(permissive: value)
                }
                Spacer()
            }
            .padding([.leading, .trailing], UIScreen.main.bounds.width * 0.10)
        }
        .onAppear(perform: {
            viewModel.loadPreSharedKey()
        })
        .navigationViewStyle(StackNavigationViewStyle())
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .navigationBarItems(leading: CustomBackButton(text: "Advanced", action: {
            presentationMode.wrappedValue.dismiss()
        }))
        .onTapGesture {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
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
        // Allow empty string as valid input
        if input.isEmpty {
            return true
        }

        // Check if the string is valid Base64
        guard let data = Data(base64Encoded: input) else {
            return false
        }

        // Check if the decoded data is 32 bytes (256 bits)
        return data.count == 32
    }
}

struct AdvancedView_Previews: PreviewProvider {
    static var previews: some View {
        AdvancedView()
    }
}
