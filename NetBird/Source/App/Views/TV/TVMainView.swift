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

// MARK: - tvOS Color Helpers (local definition)
private struct TVColors {
    static var textPrimary: Color {
        UIColor(named: "TextPrimary") != nil ? Color("TextPrimary") : .primary
    }
    static var textSecondary: Color {
        UIColor(named: "TextSecondary") != nil ? Color("TextSecondary") : .secondary
    }
    static var bgMenu: Color {
        UIColor(named: "BgMenu") != nil ? Color("BgMenu") : Color(white: 0.1)
    }
    static var bgPrimary: Color {
        UIColor(named: "BgPrimary") != nil ? Color("BgPrimary") : Color(white: 0.15)
    }
    static var bgSecondary: Color {
        UIColor(named: "BgSecondary") != nil ? Color("BgSecondary") : Color(white: 0.08)
    }
}

/// The main view for Apple TV, using top-level tab navigation.
struct TVMainView: View {
    @EnvironmentObject var viewModel: ViewModel

    /// Currently selected tab
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            // MARK: - Connection Tab (Home)
            TVConnectionView()
                .tabItem {
                    Label("Connection", systemImage: "network")
                }
                .tag(0)

            // MARK: - Peers Tab
            TVPeersView()
                .tabItem {
                    Label("Peers", systemImage: "person.3.fill")
                }
                .tag(1)

            // MARK: - Networks Tab
            TVNetworksView()
                .tabItem {
                    Label("Networks", systemImage: "globe")
                }
                .tag(2)

            // MARK: - Settings Tab (replaces side drawer)
            TVSettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .tag(3)
        }
        .environmentObject(viewModel)
        // MARK: - Authentication Sheet (QR Code + Device Code)
        .fullScreenCover(isPresented: $viewModel.networkExtensionAdapter.showBrowser) {
            if let loginURL = viewModel.networkExtensionAdapter.loginURL {
                TVAuthView(
                    loginURL: loginURL,
                    userCode: viewModel.networkExtensionAdapter.userCode,
                    isPresented: $viewModel.networkExtensionAdapter.showBrowser,
                    onCancel: {
                        // User cancelled authentication
                        viewModel.networkExtensionAdapter.showBrowser = false
                    },
                    onComplete: {
                        // Authentication completed - start VPN connection
                        print("Login completed, starting VPN connection...")
                        viewModel.networkExtensionAdapter.startVPNConnection()
                    },
                    checkLoginComplete: { completion in
                        // Check if login is complete by asking the Network Extension directly
                        // This is more reliable because it queries the same SDK client doing the login
                        viewModel.networkExtensionAdapter.checkLoginComplete { isComplete in
                            print("TVMainView: checkLoginComplete returned \(isComplete)")
                            completion(isComplete)
                        }
                    }
                )
            }
        }
    }
}

// MARK: - Connection View (Home Screen)
/// The main connection screen showing VPN status and quick actions.
struct TVConnectionView: View {
    @EnvironmentObject var viewModel: ViewModel
    
    var body: some View {
        ZStack {
            // Background
            TVColors.bgSecondary
                .ignoresSafeArea()
            
            HStack(spacing: 100) {
                // MARK: Left Side - Connection Control
                VStack(spacing: 40) {
                    // Logo
                    Image("netbird-logo-menu")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 300)
                    
                    // Device info
                    if !viewModel.fqdn.isEmpty {
                        Text(viewModel.fqdn)
                            .font(.system(size: 28))
                            .foregroundColor(TVColors.textSecondary)
                    }
                    
                    if !viewModel.ip.isEmpty {
                        Text(viewModel.ip)
                            .font(.system(size: 24))
                            .foregroundColor(TVColors.textSecondary.opacity(0.8))
                    }
                    
                    // Big Connect/Disconnect Button
                    TVConnectionButton(viewModel: viewModel)
                    
                    // Status text
                    Text(viewModel.extensionStateText)
                        .font(.system(size: 32, weight: .medium))
                        .foregroundColor(statusColor)
                }
                .frame(maxWidth: .infinity)
                
                // MARK: Right Side - Quick Stats
                VStack(alignment: .leading, spacing: 30) {
                    Text("Network Status")
                        .font(.system(size: 32, weight: .bold))
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
    
    // MARK: Computed Properties
    
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

// MARK: - Connection Button
/// Large, focusable connect/disconnect button for tvOS.
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

// MARK: - Stat Card
/// Displays a single statistic in a card format.
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
                    .font(.system(size: 20))
                    .foregroundColor(TVColors.textSecondary)
                
                if let total = total {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(value)
                            .font(.system(size: 36, weight: .bold))
                            .foregroundColor(TVColors.textPrimary)
                        Text("/ \(total)")
                            .font(.system(size: 24))
                            .foregroundColor(TVColors.textSecondary)
                    }
                } else {
                    Text(value)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundColor(TVColors.textPrimary)
                }
            }
            
            Spacer()
        }
        .padding(.vertical, 15)
    }
}

// MARK: - Preview
struct TVMainView_Previews: PreviewProvider {
    static var previews: some View {
        TVMainView()
            .environmentObject(ViewModel())
    }
}

#endif


