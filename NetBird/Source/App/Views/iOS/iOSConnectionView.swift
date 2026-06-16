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
    @State private var ipCopied = false

    // Small badge above the toggle: "SECURED" / "NOT SECURED" / hidden during transitions
    private var statusLabel: String {
        switch viewModel.vpnDisplayState {
        case .connected:    return "SECURED"
        case .disconnected: return "NOT SECURED"
        case .connecting, .disconnecting: return ""
        }
    }

    private var statusLabelColor: Color {
        switch viewModel.vpnDisplayState {
        case .connected:    return .orange
        case .disconnected: return Color(white: 0.5)
        case .connecting, .disconnecting: return .clear
        }
    }

    // One-liner below the main status title
    private var subtitle: String {
        switch viewModel.vpnDisplayState {
        case .connected:    return "You are on the NetBird network"
        case .disconnected: return "You are not on the NetBird network"
        case .connecting, .disconnecting: return ""
        }
    }

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
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)

                    Spacer()

                    // Toggle + status text + device info — all in one centered block
                    VStack(spacing: 16) {
                        // Status badge (fixed height so layout stays stable during transitions)
                        Text(statusLabel)
                            .font(.system(size: 13, weight: .semibold))
                            .tracking(1.5)
                            .foregroundColor(statusLabelColor)
                            .frame(height: 18)
                            .animation(.easeInOut(duration: 0.25), value: statusLabel)

                        VPNToggleView(
                            vpnState: viewModel.vpnDisplayState,
                            isLocked: viewModel.buttonLock,
                            onConnect: { viewModel.connect() },
                            onDisconnect: { viewModel.close() }
                        )

                        Text(viewModel.extensionStateText)
                            .font(.system(size: 32, weight: .bold))
                            .foregroundColor(Color("TextPrimary"))

                        // Fixed height prevents layout jump when subtitle appears/disappears
                        Text(subtitle)
                            .font(.system(size: 15, weight: .regular))
                            .foregroundColor(Color("TextSecondary"))
                            .opacity(subtitle.isEmpty ? 0 : 1)
                            .frame(height: 20)
                            .animation(.easeInOut(duration: 0.25), value: subtitle)

                        // FQDN + IP with tap-to-copy
                        VStack(spacing: 6) {
                            Text(fqdnCopied ? "Copied" : viewModel.fqdn)
                                .foregroundColor(Color("TextSecondary"))
                                .font(.system(size: 15, weight: .regular))
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                                .opacity(fqdnCopied ? 0.7 : 1.0)
                                .animation(.easeInOut(duration: 0.2), value: fqdnCopied)
                                .padding(.horizontal, 16)
                                .onTapGesture {
                                    guard !viewModel.fqdn.isEmpty else { return }
                                    UIPasteboard.general.string = viewModel.fqdn
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    withAnimation(.easeInOut(duration: 0.2)) { fqdnCopied = true }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                        withAnimation(.easeInOut(duration: 0.2)) { fqdnCopied = false }
                                    }
                                }

                            Text(ipCopied ? "Copied" : viewModel.ip)
                                .foregroundColor(Color("TextSecondary"))
                                .font(.system(size: 15, weight: .regular))
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                                .opacity(ipCopied ? 0.7 : 1.0)
                                .animation(.easeInOut(duration: 0.2), value: ipCopied)
                                .onTapGesture {
                                    guard !viewModel.ip.isEmpty else { return }
                                    UIPasteboard.general.string = viewModel.ip
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    withAnimation(.easeInOut(duration: 0.2)) { ipCopied = true }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                        withAnimation(.easeInOut(duration: 0.2)) { ipCopied = false }
                                    }
                                }
                        }
                        .padding(.top, 8)
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
}

#endif
