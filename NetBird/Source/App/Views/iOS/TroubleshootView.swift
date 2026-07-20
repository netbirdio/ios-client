//
//  TroubleshootView.swift
//  NetBird
//

import SwiftUI

#if os(iOS)

struct TroubleshootView: View {
    @EnvironmentObject var viewModel: ViewModel
    @State private var showShareSheet = false
    @State private var uploadKey = ""
    @State private var showCopiedAlert = false

    var body: some View {
        Form {
            Section(header: Text("Logging")) {
                Toggle("Trace logs", isOn: $viewModel.traceLogsEnabled)
                    .toggleStyle(SwitchToggleStyle(tint: .accentColor))
            }

            Section(header: Text("Debug Bundle"), footer: Text("Sensitive data includes IP addresses, domain names, and private keys.")) {
                Toggle("Anonymize sensitive data", isOn: $viewModel.anonymizeDebugBundle)
                    .toggleStyle(SwitchToggleStyle(tint: .accentColor))

                bundleActionContent
            }

        }
        .navigationTitle("Troubleshoot")
        .navigationBarTitleDisplayMode(.inline)
        .alert(isPresented: $viewModel.showLogLevelChangedAlert) {
            Alert(
                title: Text("Changing Log Level"),
                message: Text("Changing log level will take effect after next connect."),
                dismissButton: .default(Text("OK"))
            )
        }
        .sheet(isPresented: $showShareSheet) {
            ActivityView(items: [uploadKey])
        }
        .alert("Key copied", isPresented: $showCopiedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The upload key has been copied to clipboard.")
        }
        .onDisappear {
            viewModel.debugBundleUploadState = .idle
        }
    }

    @ViewBuilder
    private var bundleActionContent: some View {
        switch viewModel.debugBundleUploadState {
        case .idle:
            Button("Upload debug bundle") {
                viewModel.uploadDebugBundle()
            }

        case .uploading:
            HStack(spacing: 10) {
                ProgressView()
                Text("Generating bundle…")
                    .foregroundColor(Color("TextSecondary"))
            }

        case .done(let key):
            VStack(alignment: .leading, spacing: 6) {
                Text("Upload key")
                    .font(.footnote)
                    .foregroundColor(Color("TextSecondary"))
                Text(key)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
            .padding(.vertical, 4)

            Button {
                UIPasteboard.general.string = key
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                showCopiedAlert = true
            } label: {
                Label("Copy key", systemImage: "doc.on.doc")
            }

            Button {
                uploadKey = key
                showShareSheet = true
            } label: {
                Label("Share key", systemImage: "square.and.arrow.up")
            }

            Button("Create new bundle") {
                viewModel.debugBundleUploadState = .idle
            }
            .foregroundColor(.accentColor)

        case .error(let message):
            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                    .foregroundColor(.red)
                    .font(.footnote)
            }
            Button("Try again") {
                viewModel.debugBundleUploadState = .idle
            }
        }
    }
}

private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#endif
