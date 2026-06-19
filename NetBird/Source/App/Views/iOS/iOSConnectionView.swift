//
//  iOSConnectionView.swift
//  NetBird
//
//  Connection tab: VPN toggle, FQDN/IP display, status indicator.
//

import SwiftUI
import NetworkExtension

#if os(iOS)

struct iOSConnectionView: View {
    @EnvironmentObject var viewModel: ViewModel
    @State private var fqdnCopied = false
    @State private var ipv4Copied = false
    @State private var ipv6Copied = false
    @State private var showAddressDetails = false

    var body: some View {
        ZStack {
            if viewModel.statusDetailsValid {
                Color("BgMenu")
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    // Profile selector
                    ProfileBadge(profileName: viewModel.activeProfileName) {
                        viewModel.navigateToProfilesView = true
                    }
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity, alignment: .center)

                    Spacer()

                    // Logo + toggle + status text + device info — all in one centered block
                    VStack(spacing: 24) {
                        Image("netbird-logo-menu")
                            .resizable()
                            .scaledToFit()
                            .frame(height: 44)

                        VPNToggleView(
                            vpnState: viewModel.vpnDisplayState,
                            isLocked: viewModel.buttonLock,
                            onConnect: { viewModel.connect() },
                            onDisconnect: { viewModel.close() }
                        )
                        .padding(.vertical, 12)

                        Text(viewModel.extensionStateText)
                            .font(.custom("InterVariable", size: 18))
                            .fontWeight(.bold)
                            .foregroundColor(Color("TextPrimary"))

                        VStack(spacing: 15) {
                            Text(fqdnCopied ? "Copied" : viewModel.fqdn)
                                .font(.custom("JetBrainsMono-Regular", size: 15))
                                .foregroundColor(Color("TextPrimary"))
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                                .opacity(fqdnCopied ? 0.7 : 1.0)
                                .animation(.easeInOut(duration: 0.2), value: fqdnCopied)
                                .padding(.horizontal, 16)
                                .contentShape(Rectangle().inset(by: -12))
                                .onTapGesture { copy(viewModel.fqdn, into: $fqdnCopied) }
                            
                            // Expandable IP details: tap to reveal IPv4 + IPv6 with copy actions.
                            // The dropdown is an overlay (not part of the VStack flow) so it doesn't
                            // change this block's height and shift the centered content above it.
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showAddressDetails.toggle()
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Text(viewModel.ip)
                                        .font(.custom("JetBrainsMono-Regular", size: 15))
                                        .foregroundColor(Color("TextSecondary"))
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.5)
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(Color("TextSecondary"))
                                        .rotationEffect(.degrees(showAddressDetails ? 0 : 180))
                                }
                                .contentShape(Rectangle().inset(by: -12))
                            }
                            .padding(.top, 4)
                            .overlay(alignment: .top) {
                                if showAddressDetails {
                                    VStack(spacing: 0) {
                                        addressRow(value: viewModel.ip, copied: $ipv4Copied)
                                        Divider().background(Color("TextSecondary").opacity(0.2))
                                        addressRow(value: viewModel.ipv6, copied: $ipv6Copied)
                                    }
                                    .frame(width: UIScreen.main.bounds.width - 92)
                                    .background(Color("BgMenu"))
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color("TextSecondary").opacity(0.2)))
                                    .offset(y: 36)
                                    .padding(.top, 10)
                                    .transition(.opacity)
                                }
                            }
                        }
                    }

                    Spacer()
                }

                // Network warning shown above tab bar when connected but offline
                if viewModel.vpnDisplayState == .connected && !viewModel.isInternetConnected {
                    GeometryReader { geo in
                        VStack {
                            Spacer()
                            NetworkWarningBanner()
                                .padding(.bottom, geo.safeAreaInsets.bottom + 80)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .animation(.easeInOut(duration: 0.3), value: viewModel.isInternetConnected)
                }

                NavigationLink("", destination: ProfilesListView(), isActive: $viewModel.navigateToProfilesView)
                    .hidden()

                NavigationLink("", destination: ServerView(), isActive: $viewModel.navigateToServerView)
                    .hidden()
                    .onChange(of: viewModel.navigateToServerView) { newValue in
                        if !newValue {
                            viewModel.startPollingDetails()
                        }
                    }

            } else {
                // Loading placeholder while extension state is unknown
                ZStack {
                    Color("BgMenu").ignoresSafeArea()
                    Image("netbird-logo-menu")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 200)
                }
            }

            // Safari-based login flow
            if viewModel.networkExtensionAdapter.showBrowser,
               let loginURLString = viewModel.networkExtensionAdapter.loginURL,
               let loginURL = URL(string: loginURLString)
            {
                SafariView(
                    isPresented: $viewModel.networkExtensionAdapter.showBrowser,
                    url: loginURL,
                    didFinish: {
                        print("Finish login")
                        viewModel.networkExtensionAdapter.startVPNConnection()
                    }
                )
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarHidden(true)
    }

    @ViewBuilder
    private func addressRow(value: String, copied: Binding<Bool>) -> some View {
        HStack {
            Text(copied.wrappedValue ? "Copied" : (value.isEmpty ? "—" : value))
                .font(.custom("JetBrainsMono-Regular", size: 14))
                .foregroundColor(Color("TextPrimary"))
                .lineLimit(1)
                .truncationMode(.middle)
                .opacity(copied.wrappedValue ? 0.7 : 1.0)
                .animation(.easeInOut(duration: 0.2), value: copied.wrappedValue)

            Spacer()

            Button {
                copy(value, into: copied)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 14))
                    .foregroundColor(Color("TextSecondary"))
                    .contentShape(Rectangle().inset(by: -10))
            }
            .disabled(value.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func copy(_ value: String, into flag: Binding<Bool>) {
        guard !value.isEmpty else { return }
        UIPasteboard.general.string = value
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.easeInOut(duration: 0.2)) { flag.wrappedValue = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            withAnimation(.easeInOut(duration: 0.2)) { flag.wrappedValue = false }
        }
    }
}

#endif
