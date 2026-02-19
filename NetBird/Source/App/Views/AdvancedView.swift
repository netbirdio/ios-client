//
//  AdvancedView.swift
//  NetBirdiOS
//
//  Created by Pascal Fischer on 01.08.23.
//

import SwiftUI

struct AdvancedView: View {
    @EnvironmentObject var viewModel: ViewModel

    var body: some View {
        Form {
            Section {
                if viewModel.presharedKeySecure {
                    SecureField("Pre-shared key", text: $viewModel.presharedKey)
                        .disabled(true)
                } else {
                    TextField("Pre-shared key", text: $viewModel.presharedKey)
                        .disableAutocorrection(true)
                        .autocapitalization(.none)
                        .onChange(of: viewModel.presharedKey) { value in
                            checkForValidPresharedKey(text: value)
                        }
                }

                if viewModel.showInvalidPresharedKeyAlert {
                    Text("Invalid key")
                        .foregroundColor(.red)
                        .font(.footnote)
                }

                Button(viewModel.presharedKeySecure ? "Remove" : "Save") {
                    if !viewModel.showInvalidPresharedKeyAlert {
                        if viewModel.presharedKeySecure {
                            viewModel.removePreSharedKey()
                        } else {
                            viewModel.updatePreSharedKey()
                        }
                    }
                }
            } header: {
                Text("Pre-shared Key")
            } footer: {
                Text("You will only communicate with peers that use the same key.")
            }

            Section(header: Text("Logging")) {
                Toggle("Trace logs", isOn: $viewModel.traceLogsEnabled)
                    .toggleStyle(SwitchToggleStyle(tint: .accentColor))

                Button("Share logs") {
                    shareButtonTapped()
                }
            }

            Section(header: Text("Rosenpass")) {
                Toggle("Enable Rosenpass", isOn: $viewModel.rosenpassEnabled)
                    .toggleStyle(SwitchToggleStyle(tint: .accentColor))
                    .onChange(of: viewModel.rosenpassEnabled) { value in
                        if !value {
                            viewModel.rosenpassPermissive = false
                        }
                        viewModel.setRosenpassEnabled(enabled: value)
                    }

                Toggle("Permissive mode", isOn: $viewModel.rosenpassPermissive)
                    .toggleStyle(SwitchToggleStyle(tint: .accentColor))
                    .onChange(of: viewModel.rosenpassPermissive) { value in
                        if value {
                            viewModel.rosenpassEnabled = true
                        }
                        viewModel.setRosenpassPermissive(permissive: value)
                    }
            }

            Section(header: Text("Network & Security")) {
                Toggle("Force relay connection", isOn: $viewModel.forceRelayConnection)
                    .toggleStyle(SwitchToggleStyle(tint: .accentColor))
                    .onChange(of: viewModel.forceRelayConnection) { value in
                        viewModel.setForcedRelayConnection(isEnabled: value)
                    }
            }
        }
        .onAppear {
            viewModel.loadRosenpassSettings()
            viewModel.loadPreSharedKey()
        }
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
        .alert(isPresented: $viewModel.showLogLevelChangedAlert) {
            Alert(
                title: Text("Changing Log Level"),
                message: Text("Changing log level will take effect after next connect."),
                dismissButton: .default(Text("OK"))
            )
        }
        .alert(isPresented: $viewModel.showForceRelayAlert) {
            Alert(
                title: Text("Force Relay"),
                message: Text("To apply the setting, you will need to reconnect."),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    func shareButtonTapped() {
        Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            let tempDir = fileManager.temporaryDirectory.appendingPathComponent("netbird-logs-\(UUID().uuidString)")

            do {
                try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
            } catch {
                AppLogger.shared.log("Failed to create temp directory: \(error)")
                return
            }

            var filesToShare: [URL] = []

            if let goLogURL = AppLogger.getGoLogFileURL() {
                let goLogPath = tempDir.appendingPathComponent("netbird-engine.log")
                do {
                    try fileManager.copyItem(at: goLogURL, to: goLogPath)
                    filesToShare.append(goLogPath)
                } catch {
                    AppLogger.shared.log("Failed to export Go log: \(error)")
                }
            }

            if let swiftLogURL = AppLogger.getLogFileURL() {
                let swiftLogPath = tempDir.appendingPathComponent("netbird-app.log")
                do {
                    try fileManager.copyItem(at: swiftLogURL, to: swiftLogPath)
                    filesToShare.append(swiftLogPath)
                } catch {
                    AppLogger.shared.log("Failed to export Swift log: \(error)")
                }
            }

            guard !filesToShare.isEmpty else {
                AppLogger.shared.log("No log files to share")
                try? FileManager.default.removeItem(at: tempDir)
                return
            }

            let readOnlyFilesToShare = filesToShare

            await MainActor.run {
                let activityViewController = UIActivityViewController(activityItems: readOnlyFilesToShare, applicationActivities: nil)

                activityViewController.excludedActivityTypes = [
                    .assignToContact,
                    .saveToCameraRoll
                ]

                activityViewController.completionWithItemsHandler = { _, _, _, _ in
                    do {
                        try FileManager.default.removeItem(at: tempDir)
                    } catch {
                        AppLogger.shared.log("Failed to cleanup temp log files: \(error)")
                    }
                }

                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let rootViewController = windowScene.windows.first?.rootViewController {
                    if let popover = activityViewController.popoverPresentationController {
                        popover.sourceView = rootViewController.view
                        popover.sourceRect = CGRect(x: rootViewController.view.bounds.midX,
                                                    y: rootViewController.view.bounds.midY,
                                                    width: 0, height: 0)
                        popover.permittedArrowDirections = []
                    }
                    rootViewController.present(activityViewController, animated: true, completion: nil)
                } else {
                    AppLogger.shared.log("Unable to present share sheet (no rootViewController)")
                    try? FileManager.default.removeItem(at: tempDir)
                }
            }
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
