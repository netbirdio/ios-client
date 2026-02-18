//
//  TVMainView.swift
//  NetBird
//
//  Main navigation structure for tvOS.
//
//  Key differences from iOS:
//  - Uses TabView at the top (tvOS standard)
//  - No swipe gestures (uses Siri Remote focus navigation)
//  - Larger text and touch targets for "10-foot experience"
//  - No side drawer (replaced with Settings tab)
//

import SwiftUI
import UIKit
import NetworkExtension
import NetBirdSDK
import os

#if os(tvOS)

private let buttonLogger = Logger(subsystem: "io.netbird.app", category: "TVConnectionButton")

struct TVMainView: View {
    @EnvironmentObject var viewModel: ViewModel

    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            TVConnectionView()
                .tabItem {
                    Label("Connection", systemImage: "network")
                }
                .tag(0)

            TVPeersView()
                .tabItem {
                    Label("Peers", systemImage: "person.3.fill")
                }
                .tag(1)

            TVNetworksView()
                .tabItem {
                    Label("Networks", systemImage: "globe")
                }
                .tag(2)

            TVSettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .tag(3)
        }
        .overlay(alignment: .topLeading) {
            Image("netbird-logo-menu")
                .resizable()
                .scaledToFit()
                .frame(width: 160)
                .allowsHitTesting(false)
        }
        .environmentObject(viewModel)
        // Server configuration sheet (change server)
        .fullScreenCover(isPresented: $viewModel.navigateToServerView) {
            TVServerView(isPresented: $viewModel.navigateToServerView)
                .environmentObject(viewModel)
        }
        // Authentication Sheet (QR Code + Device Code)
        .fullScreenCover(isPresented: $viewModel.networkExtensionAdapter.showBrowser) {
            if let loginURL = viewModel.networkExtensionAdapter.loginURL {
                TVAuthView(
                    loginURL: loginURL,
                    userCode: viewModel.networkExtensionAdapter.userCode,
                    isPresented: $viewModel.networkExtensionAdapter.showBrowser,
                    onCancel: {
                        viewModel.networkExtensionAdapter.showBrowser = false
                    },
                    onComplete: {
                        #if DEBUG
                        print("Login completed, transferring config to extension...")
                        #endif
                        viewModel.networkExtensionAdapter.showBrowser = false

                        // After login completes, ensure config is transferred to extension before connecting
                        // On tvOS, shared UserDefaults doesn't work, so we must send via IPC
                        if let configJSON = Preferences.loadConfigFromUserDefaults(), !configJSON.isEmpty {
                            #if DEBUG
                            print("Sending config to extension before starting VPN...")
                            #endif
                            viewModel.networkExtensionAdapter.sendConfigToExtension(configJSON) { success in
                                #if DEBUG
                                print("Config transfer \(success ? "succeeded" : "failed"), starting VPN connection...")
                                #endif
                                // Start VPN only after config transfer completes
                                viewModel.networkExtensionAdapter.startVPNConnection()
                            }
                        } else {
                            #if DEBUG
                            print("No config found in UserDefaults, starting VPN anyway...")
                            #endif
                            // Fallback - try to connect anyway (will likely fail but better than hanging)
                            viewModel.networkExtensionAdapter.startVPNConnection()
                        }
                    },
                    onError: { errorMessage in
                        #if DEBUG
                        print("Login error: \(errorMessage)")
                        #endif
                        // Error is displayed in the auth view - user can dismiss manually
                    },
                    checkLoginComplete: { completion in
                        viewModel.networkExtensionAdapter.checkLoginComplete { isComplete in
                            #if DEBUG
                            print("TVMainView: checkLoginComplete returned \(isComplete)")
                            #endif
                            completion(isComplete)
                        }
                    },
                    checkLoginError: { completion in
                        viewModel.networkExtensionAdapter.checkLoginError { errorMessage in
                            completion(errorMessage)
                        }
                    }
                )
            }
        }
    }
}

struct TVConnectionView: View {
    @EnvironmentObject var viewModel: ViewModel

    var body: some View {
        ZStack {
            // Gradient background — subtle glow when connected
            TVGradientBackground(showAccentGlow: viewModel.extensionStateText == "Connected")

            // Central content — fully centered on screen
            VStack(spacing: 0) {
                Spacer()

                // Hero: device info + button + status
                VStack(spacing: 28) {
                    if !viewModel.fqdn.isEmpty {
                        Text(viewModel.fqdn)
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundColor(TVColors.textSecondary)
                    }

                    if !viewModel.ip.isEmpty {
                        Text(viewModel.ip)
                            .font(.system(size: 30, weight: .medium, design: .monospaced))
                            .foregroundColor(TVColors.textSecondary.opacity(0.7))
                    }

                    TVConnectionButton(viewModel: viewModel)
                        .padding(.vertical, 16)

                    Text(viewModel.extensionStateText)
                        .font(.system(size: 42, weight: .bold))
                        .foregroundColor(statusColor)
                }

                Spacer()

                // Bottom stats bar — glanceable network overview
                HStack(spacing: 50) {
                    TVCompactStatCard(
                        icon: "person.3.fill",
                        title: "Peers",
                        value: connectedPeersCount,
                        total: totalPeersCount
                    )

                    Divider()
                        .frame(height: 44)
                        .overlay(Color.white.opacity(0.12))

                    TVCompactStatCard(
                        icon: "globe",
                        title: "Networks",
                        value: activeNetworksCount,
                        total: totalNetworksCount
                    )

                    Divider()
                        .frame(height: 44)
                        .overlay(Color.white.opacity(0.12))

                    TVCompactStatCard(
                        icon: "clock.fill",
                        title: "Status",
                        value: viewModel.extensionStateText,
                        total: nil
                    )
                }
                .padding(.horizontal, 60)
                .padding(.vertical, 28)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color.white.opacity(0.05))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                )
                .padding(.horizontal, 120)
                .padding(.bottom, 50)
            }
        }
    }
    
    // Computed Properties
    
    private var statusColor: Color {
        switch viewModel.extensionStateText {
        case "Connected": return .green
        case "Connecting": return .orange
        case "Disconnecting": return .orange
        default: return TVColors.textSecondary
        }
    }
    
    private var connectedPeersCount: String {
        guard viewModel.extensionStateText == "Connected" else { return "0" }
        return viewModel.peerViewModel.peerInfo.filter { $0.connStatus == "Connected" }.count.description
    }
    
    private var totalPeersCount: String {
        guard viewModel.extensionStateText == "Connected" else { return "0" }
        return viewModel.peerViewModel.peerInfo.count.description
    }
    
    private var activeNetworksCount: String {
        guard viewModel.extensionStateText == "Connected" else { return "0" }
        return viewModel.routeViewModel.routeInfo.filter { $0.selected }.count.description
    }
    
    private var totalNetworksCount: String {
        guard viewModel.extensionStateText == "Connected" else { return "0" }
        return viewModel.routeViewModel.routeInfo.count.description
    }
}

/// Custom button style that adds a press-down scale animation for tactile feedback.
struct TVConnectButtonStyle: ButtonStyle {
    let isFocused: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : (isFocused ? 1.12 : 1.0))
            .brightness(configuration.isPressed ? -0.1 : 0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
            .animation(.easeInOut(duration: 0.25), value: isFocused)
    }
}

struct TVConnectionButton: View {
    @ObservedObject var viewModel: ViewModel

    /// Track focus state for visual feedback
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: handleTap) {
            HStack(spacing: 20) {
                Image(systemName: buttonIcon)
                    .font(.system(size: 40))

                Text(buttonText)
                    .font(.system(size: 32, weight: .semibold))
            }
            .foregroundColor(isFocused && !isConnected ? .black : .white)
            .padding(.horizontal, 80)
            .padding(.vertical, 30)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(
                        LinearGradient(
                            colors: gradientColors,
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(Color.white.opacity(isFocused ? 0.3 : 0), lineWidth: 2)
            )
            .shadow(
                color: isFocused ? buttonColor.opacity(0.6) : .clear,
                radius: isFocused ? 20 : 0,
                y: isFocused ? 8 : 0
            )
        }
        .buttonStyle(TVConnectButtonStyle(isFocused: isFocused))
        .focused($isFocused)
        .disabled(viewModel.buttonLock)
    }

    /// Gradient colors: focused state gets a top-to-bottom gradient for depth;
    /// unfocused state is slightly dimmed so focused contrast is stronger.
    private var gradientColors: [Color] {
        if isFocused {
            return [buttonColor, buttonColor.opacity(0.7)]
        }
        return [buttonColor.opacity(0.8), buttonColor.opacity(0.8)]
    }
    
    private var isConnected: Bool {
        viewModel.extensionStateText == "Connected"
    }

    private var buttonText: String {
        switch viewModel.extensionStateText {
        case "Connected": return "Disconnect"
        case "Connecting": return "Connecting..."
        case "Disconnecting": return "Disconnecting..."
        default: return "Connect"
        }
    }
    
    private var buttonIcon: String {
        switch viewModel.extensionStateText {
        case "Connected": return "stop.fill"
        case "Connecting", "Disconnecting": return "hourglass"
        default: return "play.fill"
        }
    }
    
    private var buttonColor: Color {
        switch viewModel.extensionStateText {
        case "Connected": return .red.opacity(0.8)
        case "Connecting", "Disconnecting": return .orange
        default: return .accentColor
        }
    }
    
    private func handleTap() {
        buttonLogger.info("handleTap: called, buttonLock=\(viewModel.buttonLock), extensionStateText=\(viewModel.extensionStateText)")
        guard !viewModel.buttonLock else {
            buttonLogger.info("handleTap: buttonLock is true, returning early")
            return
        }

        if viewModel.extensionStateText == "Connected" ||
           viewModel.extensionStateText == "Connecting" {
            buttonLogger.info("handleTap: calling viewModel.close()")
            viewModel.close()
        } else {
            buttonLogger.info("handleTap: calling viewModel.connect()")
            viewModel.connect()
        }
    }
}

/// Compact stat card designed for the horizontal bottom bar.
struct TVCompactStatCard: View {
    let icon: String
    let title: String
    let value: String
    let total: String?

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 26))
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(TVColors.textSecondary)

                if let total = total {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(value)
                            .font(.system(size: 30, weight: .bold))
                            .foregroundColor(TVColors.textPrimary)
                        Text("/ \(total)")
                            .font(.system(size: 22))
                            .foregroundColor(TVColors.textSecondary)
                    }
                } else {
                    Text(value)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(TVColors.textPrimary)
                }
            }
        }
    }
}

struct TVMainView_Previews: PreviewProvider {
    static var previews: some View {
        TVMainView()
            .environmentObject(ViewModel())
    }
}

#endif


