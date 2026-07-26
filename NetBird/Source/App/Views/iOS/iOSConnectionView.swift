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
    /// True once loginBrowserDidFinish ran for the current login-browser sheet.
    /// Lets the sheet's onDismiss distinguish a swipe-down (nothing handled yet →
    /// user cancel) from a dismissal that followed the Cancel button / auto-close.
    @State private var loginBrowserCompletionHandled = false

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

        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarHidden(true)
        // Login browser sheet — presented regardless of statusDetailsValid. One
        // logic for every profile: persistent cookies scoped to the profile's own
        // web store (the IdP's trusted-device 2FA cookie survives → no repeated
        // OTP prompt) and auto-close after the OAuth loopback redirect. Profiles
        // can never see each other's IdP sessions.
        .sheet(
            isPresented: $viewModel.networkExtensionAdapter.showBrowser,
            onDismiss: {
                // A swipe-down dismissal bypasses the browser's own callbacks —
                // treat it as a user cancel so the pending login doesn't dangle.
                // When the Cancel button or the auto-close already ran,
                // loginBrowserDidFinish handled completion before the dismissal.
                if !loginBrowserCompletionHandled {
                    loginBrowserDidFinish(userCancelled: true)
                }
            }
        ) {
            if let loginURLString = viewModel.networkExtensionAdapter.loginURL,
               let loginURL = URL(string: loginURLString)
            {
                ProfileLoginWebView(
                    isPresented: $viewModel.networkExtensionAdapter.showBrowser,
                    profileName: ProfileManager.shared.getActiveProfileName(),
                    url: loginURL,
                    didFinish: loginBrowserDidFinish
                )
                .onAppear { loginBrowserCompletionHandled = false }
            }
        }
    }

    /// Completion for the login browser.
    private func loginBrowserDidFinish(userCancelled: Bool) {
        loginBrowserCompletionHandled = true
        let adapter = viewModel.networkExtensionAdapter
        if userCancelled {
            // Explicit Cancel tap. Do NOT start the VPN — that would launch the
            // extension, trip its needs-login path, and pop a spurious
            // "Login required" alert/notification.
            print("Login cancelled by user")
            viewModel.cancelPendingLogin()
            return
        }
        if adapter.loginSucceeded {
            print("Finish login")
            adapter.startVPNConnection()
            return
        }
        // The browser auto-closed after the loopback redirect, but the SDK hasn't
        // reported success yet — a first-time profile registration can outlast the
        // browser's close grace. The adapter starts the VPN itself when success
        // arrives (see performLogin's onSuccess); here only arm a fallback reset
        // for the case where the login errors out instead of succeeding.
        print("Login still completing after browser closed - deferring to SDK result")
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            let adapter = viewModel.networkExtensionAdapter
            if !adapter.loginSucceeded && !adapter.showBrowser {
                print("Login did not complete after browser closed - resetting")
                viewModel.cancelPendingLogin()
            }
        }
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
