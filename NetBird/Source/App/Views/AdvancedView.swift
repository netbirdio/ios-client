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
                .edgesIgnoringSafeArea(.all)
            
            ScrollView { 
                VStack(alignment: .leading) {
                    Text("Add a pre-shared key")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(Color("TextPrimary"))
                        .padding(.top, UIScreen.main.bounds.height * 0.04)
                        .fixedSize(horizontal: false, vertical: true)
                    
                    Text("You will only communicate with peers that use the same key.")
                        .multilineTextAlignment(.leading)
                        .font(.system(size: 18, weight: .regular))
                        .foregroundColor(Color("TextSecondary"))
                        .padding(.top, 3)
                        .fixedSize(horizontal: false, vertical: true)
                    
                    CustomTextField(placeholder: "Add a pre-shared key", text: $viewModel.presharedKey, secure: $viewModel.presharedKeySecure, height: 48)
                        .padding(.top, 3)
                        .onChange(of: viewModel.presharedKey) { value in
                            checkForValidPresharedKey(text: value)
                        }
                    
                    if viewModel.showInvalidPresharedKeyAlert {
                        Text("Invalid key")
                            .foregroundColor(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    
                    SolidButton(text: viewModel.presharedKeySecure ? "Remove" : "Save") {
                        if !viewModel.showInvalidPresharedKeyAlert {
                            if viewModel.presharedKeySecure {
                                viewModel.removePreSharedKey()
                            } else {
                                viewModel.updatePreSharedKey()
                                print("save preshared key")
                                presentationMode.wrappedValue.dismiss()
                            }
                        }
                    }
                    .padding(.top, 10)
                    
                    Divider()
                        .padding([.top, .bottom])
                    
                    Toggle(isOn: $viewModel.traceLogsEnabled) {
                        Text("Enable Trace logs")
                            .multilineTextAlignment(.leading)
                            .font(.system(size: 18, weight: .regular))
                            .foregroundColor(Color("TextSecondary"))
                            .padding(.top, 3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .toggleStyle(SwitchToggleStyle(tint: .orange))
                    
                    SolidButton(text: "Share logs") {
                        shareButtonTapped()
                    }
                    .padding(.top, 3)
                    
                    Divider()
                        .padding([.top, .bottom])
                    
                    Toggle(isOn: $viewModel.rosenpassEnabled) {
                        Text("Enable Rosenpass")
                            .multilineTextAlignment(.leading)
                            .font(.system(size: 18, weight: .regular))
                            .foregroundColor(Color("TextSecondary"))
                            .padding(.top, 3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .toggleStyle(SwitchToggleStyle(tint: .orange))
                    .onChange(of: viewModel.rosenpassEnabled) { value in
                        if !value {
                            viewModel.rosenpassPermissive = false
                        }
                        viewModel.setRosenpassEnabled(enabled: value)
                    }
                    
                    Toggle(isOn: $viewModel.rosenpassPermissive) {
                        Text("Enable Rosenpass permissive mode")
                            .multilineTextAlignment(.leading)
                            .font(.system(size: 18, weight: .regular))
                            .foregroundColor(Color("TextSecondary"))
                            .padding(.top, 3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .toggleStyle(SwitchToggleStyle(tint: .orange))
                    .onChange(of: viewModel.rosenpassPermissive) { value in
                        if value {
                            viewModel.rosenpassEnabled = true
                        }
                        viewModel.setRosenpassPermissive(permissive: value)
                    }
                    
                    Divider()
                        .padding([.top, .bottom])
                    
                    Text("Network & Security")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(Color("TextPrimary"))
                        .padding(.top, 8)
                        .fixedSize(horizontal: false, vertical: true)
                    
                    Toggle(isOn: $viewModel.forceRelayConnection) {
                        Text("Force relay connection")
                            .multilineTextAlignment(.leading)
                            .font(.system(size: 18, weight: .regular))
                            .foregroundColor(Color("TextSecondary"))
                            .padding(.top, 3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .toggleStyle(SwitchToggleStyle(tint: .orange))
                    .onChange(of: viewModel.forceRelayConnection) { value in
                        viewModel.setForcedRelayConnection(isEnabled: value)
                    }
                    
                    Spacer()
                }
                .padding([.leading, .trailing], UIScreen.main.bounds.width * 0.10)
                .frame(maxWidth: .infinity, alignment: .leading) // Ensures VStack uses full width
            }
            .ignoresSafeArea(.keyboard) // Prevents keyboard from shifting views up
            
            alertOverlay(isPresented: viewModel.showLogLevelChangedAlert, onDismiss: {
                viewModel.showLogLevelChangedAlert = false
            }) {
                LogLevelAlert()
            }

            alertOverlay(isPresented: viewModel.showForceRelayAlert, onDismiss: {
                viewModel.showForceRelayAlert = false
            }) {
                ForceRelayAlert()
            }
        }
        .onAppear {
            viewModel.loadPreSharedKey()
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .navigationBarItems(leading: CustomBackButton(text: "Advanced") {
            presentationMode.wrappedValue.dismiss()
        })
        .onTapGesture {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }
    
    @ViewBuilder
    private func alertOverlay<Content: View>(
        isPresented: Bool,
        onDismiss: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if isPresented {
            Color.black.opacity(0.4)
                .edgesIgnoringSafeArea(.all)
                .onTapGesture {
                    viewModel.buttonLock = true
                    onDismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        viewModel.buttonLock = false
                    }
                }

            content()
                .frame(maxWidth: UIScreen.main.bounds.width * 0.9)
        }
    }

    func shareButtonTapped() {
        guard let documentsDir = getDocumentsDirectory() else {
            AppLogger.shared.log("Failed to get documents directory")
            return
        }

        var filesToShare: [URL] = []

        // Export Go SDK logs
        if let goLogURL = AppLogger.getGoLogFileURL() {
            do {
                let goLogData = try String(contentsOf: goLogURL, encoding: .utf8)
                let goLogPath = documentsDir.appendingPathComponent("netbird-engine.log")
                try goLogData.write(to: goLogPath, atomically: true, encoding: .utf8)
                filesToShare.append(goLogPath)
            } catch {
                AppLogger.shared.log("Failed to read Go log data: \(error)")
            }
        }

        // Export Swift logs
        if let swiftLogURL = AppLogger.getLogFileURL() {
            do {
                let swiftLogData = try String(contentsOf: swiftLogURL, encoding: .utf8)
                let swiftLogPath = documentsDir.appendingPathComponent("netbird-app.log")
                try swiftLogData.write(to: swiftLogPath, atomically: true, encoding: .utf8)
                filesToShare.append(swiftLogPath)
            } catch {
                AppLogger.shared.log("Failed to read Swift log data: \(error)")
            }
        }

        guard !filesToShare.isEmpty else {
            AppLogger.shared.log("No log files to share")
            return
        }

        let activityViewController = UIActivityViewController(activityItems: filesToShare, applicationActivities: nil)

        activityViewController.excludedActivityTypes = [
            .assignToContact,
            .saveToCameraRoll
        ]

        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootViewController = windowScene.windows.first?.rootViewController {
            // Configure popover for iPad to prevent crash
            if let popover = activityViewController.popoverPresentationController {
                popover.sourceView = rootViewController.view
                popover.sourceRect = CGRect(x: rootViewController.view.bounds.midX,
                                            y: rootViewController.view.bounds.midY,
                                            width: 0, height: 0)
                popover.permittedArrowDirections = []
            }
            rootViewController.present(activityViewController, animated: true, completion: nil)
        }
    }
        
    func getDocumentsDirectory() -> URL? {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return paths.first
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

struct ForceRelayAlert: View {
    @EnvironmentObject var viewModel: ViewModel

    var body: some View {
        VStack(spacing: 20) {
            Image("exclamation-circle")
                .renderingMode(.template)
                .padding(.top, 20)
                .foregroundColor(Color.accentColor)
            Text("To apply the setting, you will need to reconnect.")
                .foregroundColor(Color("TextAlert"))
                .multilineTextAlignment(.center)
            HStack {
                Spacer()
                Button(action: {
                    viewModel.showForceRelayAlert = false
                }) {
                    Text("OK")
                        .padding()
                        .foregroundColor(Color.accentColor)
                }
                .background(Color.clear)
                .padding(.trailing)
            }
        }
        .padding()
        .background(Color("BgSideDrawer"))
        .cornerRadius(15)
        .shadow(radius: 10)
    }
}

struct LogLevelAlert: View {
    @EnvironmentObject var viewModel: ViewModel

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
                viewModel.showLogLevelChangedAlert = false
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
