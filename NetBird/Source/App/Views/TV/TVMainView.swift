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
            // Background
            TVColors.bgSecondary
                .ignoresSafeArea()
            
            HStack(spacing: 100) {
                // Left Side - Connection Control
                VStack(spacing: 40) {
                    Image("netbird-logo-menu")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 300)
                    
                    // Device info
                    if !viewModel.fqdn.isEmpty {
                        Text(viewModel.fqdn)
                            .font(.system(size: 36, weight: .semibold))
                            .foregroundColor(TVColors.textSecondary)
                    }

                    if !viewModel.ip.isEmpty {
                        Text(viewModel.ip)
                            .font(.system(size: 32, weight: .medium, design: .monospaced))
                            .foregroundColor(TVColors.textSecondary.opacity(0.8))
                    }
                    
                    TVConnectionButton(viewModel: viewModel)
                    
                    // Status text
                    Text(viewModel.extensionStateText)
                        .font(.system(size: 40, weight: .bold))
                        .foregroundColor(statusColor)
                }
                .frame(maxWidth: .infinity)
                
                // Right Side - Quick Stats
                VStack(alignment: .leading, spacing: 30) {
                    Text("Network Status")
                        .font(.system(size: 36, weight: .bold))
                        .foregroundColor(TVColors.textPrimary)
                    
                    TVStatCard(
                        icon: "person.3.fill",
                        title: "Connected Peers",
                        value: connectedPeersCount,
                        total: totalPeersCount
                    )
                    
                    TVStatCard(
                        icon: "globe",
                        title: "Active Networks",
                        value: activeNetworksCount,
                        total: totalNetworksCount
                    )
                    
                    TVStatCard(
                        icon: "clock.fill",
                        title: "Connection Status",
                        value: viewModel.extensionStateText,
                        total: nil
                    )
                }
                .padding(50)
                .background(
                    RoundedRectangle(cornerRadius: 24)
                        .fill(TVColors.bgMenu)
                )
                .frame(width: 500)
            }
            .padding(80)
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
            .foregroundColor(.white)
            .padding(.horizontal, 80)
            .padding(.vertical, 30)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(buttonColor)
            )
            .scaleEffect(isFocused ? 1.1 : 1.0)
            .animation(.easeInOut(duration: 0.2), value: isFocused)
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .disabled(viewModel.buttonLock)
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

struct TVStatCard: View {
    let icon: String
    let title: String
    let value: String
    let total: String?
    
    var body: some View {
        HStack(spacing: 20) {
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundColor(.accentColor)
                .frame(width: 50)
            
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundColor(TVColors.textSecondary)
                
                if let total = total {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(value)
                            .font(.system(size: 40, weight: .bold))
                            .foregroundColor(TVColors.textPrimary)
                        Text("/ \(total)")
                            .font(.system(size: 30))
                            .foregroundColor(TVColors.textSecondary)
                    }
                } else {
                    Text(value)
                        .font(.system(size: 36, weight: .bold))
                        .foregroundColor(TVColors.textPrimary)
                }
            }
            
            Spacer()
        }
        .padding(.vertical, 15)
    }
}

struct TVMainView_Previews: PreviewProvider {
    static var previews: some View {
        TVMainView()
            .environmentObject(ViewModel())
    }
}

#endif


