//
//  iOSSettingsView.swift
//  NetBird
//
//  Settings tab: Advanced, About, Change Server, Documentation.
//

import SwiftUI
import NetBirdSDK

#if os(iOS)

struct iOSSettingsView: View {
    @EnvironmentObject var viewModel: ViewModel

    var body: some View {
        List {
            Section {
                NavigationLink {
                    ProfilesListView()
                } label: {
                    HStack {
                        Image(systemName: "person.2.fill")
                            .foregroundColor(.accentColor)
                            .frame(width: 24)
                        Text("Profiles")
                            .foregroundColor(Color("TextPrimary"))
                        Spacer()
                        Text(viewModel.activeProfileName)
                            .foregroundColor(Color("TextSecondary"))
                            .font(.system(size: 14))
                    }
                }
            }

            Section(header: Text("Connection")) {
                    Button {
                        viewModel.showChangeServerAlert = true
                    } label: {
                        HStack {
                            Image(systemName: "server.rack")
                                .foregroundColor(.accentColor)
                                .frame(width: 24)
                            Text("Change Server")
                                .foregroundColor(Color("TextPrimary"))
                        }
                    }
                }

                Section(header: Text("Settings")) {
                    NavigationLink {
                        VPNOnDemandView()
                    } label: {
                        HStack {
                            Image(systemName: "arrow.trianglehead.2.clockwise")
                                .foregroundColor(.accentColor)
                                .frame(width: 24)
                            Text("VPN On Demand")
                                .foregroundColor(Color("TextPrimary"))
                        }
                    }

                    NavigationLink {
                        AdvancedView()
                    } label: {
                        HStack {
                            Image(systemName: "gearshape.2")
                                .foregroundColor(.accentColor)
                                .frame(width: 24)
                            Text("Advanced")
                                .foregroundColor(Color("TextPrimary"))
                        }
                    }

                    NavigationLink {
                        TroubleshootView()
                    } label: {
                        HStack {
                            Image(systemName: "stethoscope")
                                .foregroundColor(.accentColor)
                                .frame(width: 24)
                            Text("Troubleshoot")
                                .foregroundColor(Color("TextPrimary"))
                        }
                    }

                    NavigationLink {
                        FileDropSettingsView()
                    } label: {
                        HStack {
                            Image(systemName: "arrow.down.doc")
                                .foregroundColor(.accentColor)
                                .frame(width: 24)
                            Text("Receiving files")
                                .foregroundColor(Color("TextPrimary"))
                        }
                    }
                }

                Section(header: Text("Information")) {
                    NavigationLink {
                        AboutView()
                    } label: {
                        HStack {
                            Image(systemName: "info.circle")
                                .foregroundColor(.accentColor)
                                .frame(width: 24)
                            Text("About")
                                .foregroundColor(Color("TextPrimary"))
                        }
                    }

                    if let docsURL = URL(string: "https://docs.netbird.io") {
                        Link(destination: docsURL) {
                            HStack {
                                Image(systemName: "book")
                                    .foregroundColor(.accentColor)
                                    .frame(width: 24)
                                Text("Documentation")
                                    .foregroundColor(Color("TextPrimary"))
                                Spacer()
                                Image(systemName: "arrow.up.right.square")
                                    .foregroundColor(Color("TextSecondary"))
                                    .font(.system(size: 14))
                            }
                        }
                    }
                }

                Section {
                    HStack {
                        Spacer()
                        Text("Version: \(appVersion) (core \(goVersion))")
                            .font(.system(size: 14))
                            .foregroundColor(Color("TextSecondary"))
                        Spacer()
                    }
                }
            }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    /// Version of the Go client baked into NetBirdSDK.xcframework at compile time.
    private var goVersion: String {
        let version = NetBirdSDKGoClientVersion()
        return version.isEmpty ? "unknown" : version
    }
}

/// The base policy for incoming transfers of the active profile. Per-sender
/// exceptions stay in Go and apply on top of it.
struct FileDropSettingsView: View {
    @EnvironmentObject var viewModel: ViewModel
    @ObservedObject private var filesVM = FilesViewModel.shared

    var body: some View {
        List {
            Section(footer: Text(footerText)) {
                ForEach(FileDropMode.allCases, id: \.self) { mode in
                    Button {
                        guard filesVM.mode != mode else { return }
                        UISelectionFeedbackGenerator().selectionChanged()
                        filesVM.setMode(mode)
                    } label: {
                        HStack {
                            Text(label(for: mode))
                                .foregroundColor(Color("TextPrimary"))
                            Spacer()
                            if filesVM.mode == mode {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .accessibilityAddTraits(filesVM.mode == mode ? .isSelected : [])
                }
            }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle("Receiving files")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            filesVM.bind(adapter: viewModel.networkExtensionAdapter)
            filesVM.refreshMode()
        }
    }

    private func label(for mode: FileDropMode) -> LocalizedStringKey {
        switch mode {
        case .off: return "Off"
        case .ask: return "Ask every time"
        case .autoAccept: return "Accept automatically"
        }
    }

    private var footerText: LocalizedStringKey {
        "Other peers can send you files over NetBird. Received files show up in the Files tab, where you can save or share them."
    }
}

#endif
