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
                    Label("Resources", systemImage: "globe")
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
                        viewModel.connectPressed = false
                        // The extension is parked in startTunnel waiting for this login —
                        // tear it down so it doesn't linger until the watchdog fires.
                        viewModel.close()
                        viewModel.updateVPNDisplayState()
                    },
                    onComplete: {
                        #if DEBUG
                        print("Login completed, transferring config to extension...")
                        #endif
                        viewModel.networkExtensionAdapter.showBrowser = false

                        // The extension already holds the post-login config (loginAsync
                        // saved it and loaded it into the client) and continues the
                        // parked startTunnel by itself. Only push the config and start
                        // the tunnel if it isn't already coming up — calling
                        // startVPNTunnel on a .connecting session can disrupt it.
                        guard viewModel.extensionState == .disconnected else { return }

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
                    checkLoginDiagnostics: { completion in
                        viewModel.networkExtensionAdapter.checkLoginDiagnostics { diagnostics in
                            if let diagnostics, diagnostics.isComplete {
                                viewModel.networkExtensionAdapter.persistLoginConfiguration(from: diagnostics)
                            }
                            #if DEBUG
                            print("TVMainView: checkLoginDiagnostics returned isComplete=\(diagnostics?.isComplete ?? false)")
                            #endif
                            completion(diagnostics)
                        }
                    }
                )
            }
        }
    }
}

struct TVConnectionView: View {
    @EnvironmentObject var viewModel: ViewModel

    @State private var showAddressDetails = false

    var body: some View {
        ZStack {
            TVGradientBackground(showAccentGlow: false)

            // Central content — fully centered on screen
            VStack(spacing: 0) {
                Spacer()

                // Toggle + status — always at the same vertical position
                TVVPNToggleView(
                    vpnState: viewModel.vpnDisplayState,
                    isLocked: viewModel.buttonLock,
                    onConnect: { viewModel.connect() },
                    onDisconnect: { viewModel.close() }
                )
                .padding(.vertical, 16)

                HStack(spacing: 10) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 10, height: 10)
                        .shadow(color: statusColor.opacity(0.4), radius: 4)

                    Text(viewModel.extensionStateText)
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundColor(statusColor)
                }
                .padding(.top, 28)

                // Device info sits below the toggle (mirrors the iOS layout) so the
                // expanding address dropdown grows into the empty area underneath
                // instead of pushing the toggle off-centre.
                VStack(spacing: 12) {
                    Text(viewModel.fqdn.isEmpty ? " " : viewModel.fqdn)
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundColor(TVColors.textSecondary)
                        .opacity(viewModel.fqdn.isEmpty ? 0 : 1)

                    // Reserve the collapsed row height so the block keeps a stable
                    // position, but keep the control out of the view tree entirely
                    // while there is no address — a merely transparent button would
                    // still swallow Siri Remote focus.
                    ZStack {
                        Color.clear.frame(height: 62)

                        if !viewModel.ip.isEmpty {
                            TVAddressDropdown(
                                ipv4: viewModel.ip,
                                ipv6: viewModel.ipv6,
                                isExpanded: $showAddressDetails
                            )
                        }
                    }
                }
                .padding(.top, 36)
                .onChange(of: viewModel.ip) { _, newValue in
                    if newValue.isEmpty { showAddressDetails = false }
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
                        title: "Resources",
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
        case "Connecting...", "Disconnecting...": return .orange
        default: return .red.opacity(0.8)
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
/// Applied to the toggle so tvOS does not wrap it in its default focusable card.
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

/// tvOS counterpart of the iOS `VPNToggleView`: a pill toggle driven by the Siri
/// Remote instead of a tap, sized for the 10-foot experience.
///
/// Differences from the iOS version that matter on TV:
/// - Wrapped in a `Button` so the focus engine can reach it (`onTapGesture` never
///   fires on tvOS — there is no touch input).
/// - Never `.disabled()`. A disabled view is dropped from the focus tree, so
///   locking the toggle mid-connect would yank focus up into the tab bar and
///   leave the user stranded. The lock is enforced inside the action instead.
/// - Carries an explicit focus ring, because the custom `ButtonStyle` opts out of
///   the system focus treatment.
struct TVVPNToggleView: View {
    let vpnState: VPNDisplayState
    let isLocked: Bool
    let onConnect: () -> Void
    let onDisconnect: () -> Void

    @FocusState private var isFocused: Bool
    @State private var pulseOpacity: Double = 1.0
    // Optimistic override: set immediately on select so the thumb moves without
    // waiting for the OS to report the new tunnel state
    @State private var optimisticIsOn: Bool? = nil

    private var isOn: Bool {
        optimisticIsOn ?? (vpnState == .connected || vpnState == .connecting)
    }

    private var isTransitioning: Bool {
        optimisticIsOn != nil || vpnState == .connecting || vpnState == .disconnecting
    }

    private let trackWidth: CGFloat = 220
    private let trackHeight: CGFloat = 112
    private var thumbDiameter: CGFloat { trackHeight - 16 }
    private var thumbTravel: CGFloat { (trackWidth - thumbDiameter) / 2 - 8 }

    var body: some View {
        Button(action: handleSelect) {
            ZStack {
                Capsule()
                    .fill(isOn ? Color.orange : Color.white.opacity(0.22))
                    .opacity(pulseOpacity)
                    .frame(width: trackWidth, height: trackHeight)
                    .animation(.easeInOut(duration: 0.3), value: isOn)

                Circle()
                    .fill(Color.white)
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .offset(x: isOn ? thumbTravel : -thumbTravel)
                    .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 4)
                    .animation(.spring(response: 0.38, dampingFraction: 0.75), value: isOn)
            }
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(isFocused ? 0.9 : 0), lineWidth: 5)
                    .frame(width: trackWidth, height: trackHeight)
            )
            .shadow(
                color: isFocused ? (isOn ? Color.orange : Color.white).opacity(0.45) : .clear,
                radius: isFocused ? 28 : 0,
                y: isFocused ? 8 : 0
            )
            .animation(.easeInOut(duration: 0.2), value: isFocused)
        }
        .buttonStyle(TVConnectButtonStyle(isFocused: isFocused))
        .focused($isFocused)
        .accessibilityLabel("VPN connection")
        .accessibilityValue(isOn ? "On" : "Off")
        // Clear optimistic as soon as the OS confirms any state change
        .onChange(of: vpnState) {
            optimisticIsOn = nil
        }
        // Bounded fallback. A disconnect tap does not always move vpnState: when the
        // extension is .connected or .connecting, updateVPNDisplayState() maps back to
        // the same display state, so onChange never fires. That is fine while the OS
        // reports the teardown a moment later — but if stop() is silently dropped, the
        // override would hold the thumb in the wrong position and keep the pulse
        // looping forever. Expire it so the UI falls back to the real state.
        .task(id: optimisticIsOn) {
            guard optimisticIsOn != nil else { return }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            optimisticIsOn = nil
        }
        // Drive the pulse loop with a cancellable async task keyed to transitioning state
        .task(id: isTransitioning) {
            guard isTransitioning else {
                withAnimation(.easeInOut(duration: 0.25)) { pulseOpacity = 1.0 }
                return
            }
            while !Task.isCancelled {
                withAnimation(.easeInOut(duration: 0.85)) { pulseOpacity = 0.45 }
                try? await Task.sleep(nanoseconds: 850_000_000)
                guard !Task.isCancelled else { break }
                withAnimation(.easeInOut(duration: 0.85)) { pulseOpacity = 1.0 }
                try? await Task.sleep(nanoseconds: 850_000_000)
            }
        }
    }

    private func handleSelect() {
        buttonLogger.info("handleSelect: called, isLocked=\(isLocked), vpnState=\(String(describing: vpnState))")
        guard !isLocked else {
            buttonLogger.info("handleSelect: toggle is locked, returning early")
            return
        }

        switch vpnState {
        case .disconnected:
            optimisticIsOn = true
            onConnect()
        case .connected, .connecting:
            optimisticIsOn = false
            onDisconnect()
        case .disconnecting:
            break
        }
    }
}

/// Expandable IPv4 / IPv6 readout for the tvOS connection screen.
///
/// The iOS version pairs each address with a copy-to-clipboard button; tvOS has no
/// pasteboard and nothing to paste into, so the rows are read-only. Keeping them
/// non-focusable also means the expanded panel cannot trap Siri Remote focus — only
/// the disclosure row itself participates in focus navigation.
///
/// The panel is an overlay rather than part of the stack flow, so expanding it does
/// not resize the centred block and shift the toggle above it.
struct TVAddressDropdown: View {
    let ipv4: String
    let ipv6: String
    @Binding var isExpanded: Bool

    @FocusState private var isFocused: Bool

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 14) {
                Text(ipv4.isEmpty ? "—" : ipv4)
                    .font(.system(size: 30, weight: .medium, design: .monospaced))
                    .foregroundColor(isFocused ? .black : TVColors.textSecondary.opacity(0.7))

                Image(systemName: "chevron.down")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(isFocused ? .black.opacity(0.6) : TVColors.textSecondary.opacity(0.7))
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
            // Card fill at rest, white fill when focused — the established
            // treatment for rows across the tvOS screens (see TVSettingsRow).
            .background(
                RoundedRectangle(cornerRadius: TVLayout.cornerRadiusSmall)
                    .fill(isFocused ? Color.white : Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: TVLayout.cornerRadiusSmall)
                    .stroke(Color.white.opacity(isFocused ? 0 : 0.08), lineWidth: 1)
            )
            .animation(.easeInOut(duration: 0.2), value: isFocused)
        }
        .buttonStyle(TVSettingsButtonStyle())
        .focused($isFocused)
        .accessibilityLabel("IP addresses")
        .overlay(alignment: .top) {
            if isExpanded {
                VStack(spacing: 0) {
                    addressRow(label: "IPv4", value: ipv4)

                    Divider()
                        .overlay(Color.white.opacity(0.12))
                        .padding(.horizontal, 24)

                    addressRow(label: "IPv6", value: ipv6)
                }
                .frame(width: 760)
                // Same card treatment as the bottom stats bar, so the panel reads
                // as part of the tvOS layout rather than a pop-up menu.
                .background(
                    RoundedRectangle(cornerRadius: TVLayout.cornerRadiusMedium)
                        .fill(Color.white.opacity(0.05))
                        .overlay(
                            RoundedRectangle(cornerRadius: TVLayout.cornerRadiusMedium)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                )
                .offset(y: 74)
                .transition(.opacity)
            }
        }
    }

    /// Single-line row: the address is the payload, so it carries the large type
    /// while the family label stays a quiet caption. Keeping rows to one line also
    /// keeps the expanded panel clear of the bottom stats bar.
    @ViewBuilder
    private func addressRow(label: String, value: String) -> some View {
        HStack(spacing: 18) {
            Text(label)
                .font(.system(size: 22, weight: .medium))
                .foregroundColor(TVColors.textSecondary)

            Spacer(minLength: 20)

            Text(value.isEmpty ? "Not assigned" : value)
                .font(.system(size: 30, weight: .medium, design: .monospaced))
                .foregroundColor(value.isEmpty ? TVColors.textSecondary : TVColors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
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

