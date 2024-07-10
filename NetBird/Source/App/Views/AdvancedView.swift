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
                .padding(.top, 10)
                Divider()
                    .padding([.top, .bottom])
                Toggle(isOn: $viewModel.traceLogsEnabled, label: {
                    Text("Enable Trace logs.")
                        .multilineTextAlignment(.leading)
                        .font(.system(size: 18, weight: .regular))
                        .foregroundColor(Color("TextSecondary"))
                        .padding(.top, 3)
                })
                .toggleStyle(SwitchToggleStyle(tint: .orange))
                SolidButton(text: "Share logs") {
                    shareButtonTapped()
                }
                .padding(.top, 3)
                Divider()
                    .padding([.top, .bottom])
                Toggle(isOn: $viewModel.rosenpassEnabled, label: {
                    Text("Enable Rosenpass.")
                        .multilineTextAlignment(.leading)
                        .font(.system(size: 18, weight: .regular))
                        .foregroundColor(Color("TextSecondary"))
                        .padding(.top, 3)
                })
                .toggleStyle(SwitchToggleStyle(tint: .orange))
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
                .toggleStyle(SwitchToggleStyle(tint: .orange))
                .onChange(of: viewModel.rosenpassPermissive) { value in
                    if value {
                        viewModel.rosenpassEnabled = true
                    }
                    viewModel.setRosenpassPermissive(permissive: value)
                }
                Spacer()
            }
            .padding([.leading, .trailing], UIScreen.main.bounds.width * 0.10)
            if viewModel.showLogLevelChangedAlert {
                Color.black.opacity(0.4)
                    .edgesIgnoringSafeArea(.all)
                    .onTapGesture {
                        viewModel.buttonLock = true
                        viewModel.showLogLevelChangedAlert = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            viewModel.buttonLock = false
                        }
                    }
                
                LogLevelAlert(viewModel: viewModel, isPresented: $viewModel.showLogLevelChangedAlert)
                    .frame(maxWidth: UIScreen.main.bounds.width * 0.9)
            }
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
    
    func shareButtonTapped() {
        let fileManager = FileManager.default
        guard let groupURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: "group.io.netbird.app") else {
            print("Failed to retrieve the group URL")
            return
        }

        let logURL = groupURL.appendingPathComponent("logfile.log")

        do {
            let logData = try String(contentsOf: logURL, encoding: .utf8)
            let fileName = "netbird-log.txt"
            guard let filePath = getDocumentsDirectory()?.appendingPathComponent(fileName) else {
                print("Failed to get file path")
                return
            }
            
            do {
                try logData.write(to: filePath, atomically: true, encoding: .utf8)
                
                let activityViewController = UIActivityViewController(activityItems: [filePath], applicationActivities: nil)
                
                activityViewController.excludedActivityTypes = [
                    .assignToContact,
                    .saveToCameraRoll
                ]
                
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let rootViewController = windowScene.windows.first?.rootViewController {
                    rootViewController.present(activityViewController, animated: true, completion: nil)
                }
            } catch {
                print("Failed to write to file: \(error.localizedDescription)")
            }
        } catch {
            print("Failed to read log data: \(error)")
            return
        }
    }
        
    func getDocumentsDirectory() -> URL? {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return paths.first
    }
    
    func saveLogFile(at url: URL?) {
        guard let url = url else { return }

        let fileManager = FileManager.default
        guard let groupURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: "group.io.netbird.app") else {
                print("Failed to retrieve the group URL")
                return
            }

            let logURL = groupURL.appendingPathComponent("logfile.log")

            do {
                let logData = try String(contentsOf: logURL, encoding: .utf8)
                let fileURL = url.appendingPathComponent("netbird.log")
                do {
                    try logData.write(to: fileURL, atomically: true, encoding: .utf8)
                    print("Log file saved successfully.")
                } catch {
                    print("Failed to save log file: \(error)")
                }
            } catch {
                print("Failed to read log data: \(error)")
                return
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

struct LogLevelAlert: View {
    @StateObject var viewModel: ViewModel
    @Binding var isPresented: Bool
    
    var body: some View {
        VStack(spacing: 20) {
            Image("exclamation-circle")
                .padding(.top, 20)
            Text("Changing Log Level")
                .font(.title)
                .foregroundColor(Color("TextAlert"))
            Text("Changing log level will take effect after next connect.")
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

struct AdvancedView_Previews: PreviewProvider {
    static var previews: some View {
        AdvancedView()
    }
}
