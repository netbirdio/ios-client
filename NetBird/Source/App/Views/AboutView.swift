//
//  AboutView.swift
//  NetBirdiOS
//
//  Created by Pascal Fischer on 01.08.23.
//

import SwiftUI

struct AboutView: View {
    @EnvironmentObject var viewModel: ViewModel

    var body: some View {
        List {
            Section {
                HStack {
                    Spacer()
                    VStack(spacing: 12) {
                        Image("netbird-logo-menu")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 120)
                        Text("Version \(appVersion)")
                            .font(.subheadline)
                            .foregroundColor(Color("TextSecondary"))
                    }
                    Spacer()
                }
                .listRowBackground(Color.clear)
            }

            Section {
                Link(destination: URL(string: "https://netbird.io/terms")!) {
                    HStack {
                        Text("License agreement")
                            .foregroundColor(Color("TextPrimary"))
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .foregroundColor(Color("TextSecondary"))
                            .font(.system(size: 14))
                    }
                }

                Link(destination: URL(string: "https://netbird.io/privacy")!) {
                    HStack {
                        Text("Privacy policy")
                            .foregroundColor(Color("TextPrimary"))
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .foregroundColor(Color("TextSecondary"))
                            .font(.system(size: 14))
                    }
                }
            }

            Section {
                Button("Join Beta Program") {
                    viewModel.showBetaProgramAlert = true
                }
            }

            Section {
                HStack {
                    Spacer()
                    Text("\u{00A9} \(String(Calendar.current.component(.year, from: Date()))) NetBird all rights reserved")
                        .font(.footnote)
                        .foregroundColor(Color("TextSecondary"))
                    Spacer()
                }
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
        .alert(isPresented: $viewModel.showBetaProgramAlert) {
            Alert(
                title: Text("Join TestFlight Beta"),
                message: Text("By signing up for TestFlight you will receive new updates early and can give us valuable feedback before the official release."),
                primaryButton: .default(Text("Sign Up")) {
                    if let url = URL(string: "https://testflight.apple.com/join/jISzXOP8") {
                        UIApplication.shared.open(url)
                    }
                },
                secondaryButton: .cancel()
            )
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }
}

struct AboutView_Previews: PreviewProvider {
    static var previews: some View {
        AboutView()
    }
}
