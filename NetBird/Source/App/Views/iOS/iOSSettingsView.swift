//
//  iOSSettingsView.swift
//  NetBird
//
//  Settings tab: Advanced, About, Change Server, Documentation.
//

import SwiftUI

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
                        Text("Version \(appVersion)")
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
}

#endif
