//
//  TVSettingsView.swift
//  NetBird
//
//  Settings view for Apple TV.
//
//  Replaces the iOS side drawer menu.
//  Contains all configuration options in a focus-navigable format.
//

import SwiftUI
import UIKit

#if os(tvOS)

/// Settings screen for tvOS, replacing the iOS side drawer.
struct TVSettingsView: View {
    @EnvironmentObject var viewModel: ViewModel
    
    var body: some View {
        ZStack {
            TVColors.bgMenu
                .ignoresSafeArea()
            
            HStack(spacing: 0) {
                // Left Side - Settings List
                VStack(alignment: .leading, spacing: 30) {
                    Text("Settings")
                        .font(.system(size: 48, weight: .bold))
                        .foregroundColor(TVColors.textPrimary)
                        .padding(.bottom, 20)
                    
                    // Settings options
                    ScrollView {
                        VStack(spacing: 20) {
                            TVSettingsSection(title: "Connection") {
                                TVSettingsRow(
                                    icon: "server.rack",
                                    title: "Change Server",
                                    subtitle: "Switch to a different NetBird server",
                                    action: { viewModel.showChangeServerAlert = true }
                                )
                            }

                            TVSettingsSection(title: "Advanced") {
                                TVSettingsToggleRow(
                                    icon: "ant.fill",
                                    title: "Trace Logging",
                                    subtitle: "Enable detailed logs for troubleshooting",
                                    isOn: $viewModel.traceLogsEnabled
                                )

                                TVSettingsToggleRow(
                                    icon: "shield.lefthalf.filled",
                                    title: "Rosenpass",
                                    subtitle: "Post-quantum secure encryption",
                                    isOn: Binding(
                                        get: { viewModel.rosenpassEnabled },
                                        set: { newValue in
                                            // When disabling Rosenpass, also disable permissive mode
                                            if !newValue {
                                                viewModel.setRosenpassPermissive(permissive: false)
                                            }
                                            viewModel.setRosenpassEnabled(enabled: newValue)
                                        }
                                    )
                                )

                                TVSettingsToggleRow(
                                    icon: "shield.checkerboard",
                                    title: "Rosenpass Permissive",
                                    subtitle: "Allow connections with non-Rosenpass peers",
                                    isOn: Binding(
                                        get: { viewModel.rosenpassPermissive },
                                        set: { newValue in
                                            viewModel.setRosenpassPermissive(permissive: newValue)
                                        }
                                    ),
                                    isDisabled: !viewModel.rosenpassEnabled
                                )
                            }

                            TVSettingsSection(title: "Info") {
                                TVSettingsInfoRow(
                                    icon: "book.fill",
                                    title: "Documentation",
                                    subtitle: "docs.netbird.io"
                                )

                                TVSettingsInfoRow(
                                    icon: "info.circle.fill",
                                    title: "Version",
                                    subtitle: appVersion
                                )
                            }
                        }
                        .padding(.top, 15)
                        .padding(.bottom, 50)
                    }
                }
                .padding(80)
                .frame(maxWidth: .infinity, alignment: .leading)
                
                // Right Side - NetBird Branding
                VStack {
                    Spacer()
                    
                    Image("netbird-logo-menu")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 300)
                        .opacity(0.3)
                    
                    Text("Secure. Simple. Connected.")
                        .font(.system(size: 24))
                        .foregroundColor(TVColors.textSecondary.opacity(0.5))
                        .padding(.top, 20)
                    
                    Spacer()
                }
                .frame(width: 500)
                .background(TVColors.bgPrimary.opacity(0.3))
            }
            
            // Change server alert overlay
            if viewModel.showChangeServerAlert {
                TVChangeServerAlert(viewModel: viewModel)
            }

            // Rosenpass changed alert overlay
            if viewModel.showRosenpassChangedAlert {
                TVRosenpassChangedAlert(viewModel: viewModel)
            }
        }
        .onAppear {
            // Load Rosenpass settings from storage to sync UI with actual values
            viewModel.loadRosenpassSettings()
        }
    }
    
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }
}

struct TVSettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text(title.uppercased())
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(TVColors.textSecondary)
                .tracking(2)
            
            VStack(spacing: 10) {
                content()
            }
            .padding(25)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(TVColors.bgPrimary)
            )
        }
    }
}

struct TVSettingsRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let action: (() -> Void)?

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: { action?() }) {
            HStack(spacing: 20) {
                Image(systemName: icon)
                    .font(.system(size: 28))
                    .foregroundColor(.accentColor)
                    .frame(width: 40)

                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundColor(isFocused ? .white : TVColors.textPrimary)

                    Text(subtitle)
                        .font(.system(size: 18))
                        .foregroundColor(isFocused ? .white.opacity(0.8) : TVColors.textSecondary)
                }

                Spacer()

                if action != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 20))
                        .foregroundColor(isFocused ? .white : TVColors.textSecondary)
                }
            }
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isFocused ? Color.accentColor.opacity(0.2) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .disabled(action == nil)
    }
}

struct TVSettingsToggleRow: View {
    let icon: String
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    var isDisabled: Bool = false

    @FocusState private var isFocused: Bool

    var body: some View {
        // Note: We don't use .disabled() because that breaks focus navigation on tvOS.
        // Instead, we check isDisabled in the action and show visual disabled state.
        Button(action: { if !isDisabled { isOn.toggle() } }) {
            HStack(spacing: 20) {
                Image(systemName: icon)
                    .font(.system(size: 28))
                    .foregroundColor(isDisabled ? TVColors.textSecondary.opacity(0.5) : .accentColor)
                    .frame(width: 40)

                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundColor(isDisabled ? TVColors.textSecondary.opacity(0.5) : (isFocused ? .white : TVColors.textPrimary))

                    Text(subtitle)
                        .font(.system(size: 18))
                        .foregroundColor(isDisabled ? TVColors.textSecondary.opacity(0.4) : (isFocused ? .white.opacity(0.8) : TVColors.textSecondary))
                }

                Spacer()

                // Custom toggle for better TV visibility
                ZStack {
                    Capsule()
                        .fill(isDisabled ? Color.gray.opacity(0.2) : (isOn ? Color.green : Color.gray.opacity(0.3)))
                        .frame(width: 70, height: 40)

                    Circle()
                        .fill(isDisabled ? Color.gray.opacity(0.5) : Color.white)
                        .frame(width: 32, height: 32)
                        .offset(x: isOn ? 15 : -15)
                        .animation(.easeInOut(duration: 0.2), value: isOn)
                }
            }
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isFocused && !isDisabled ? Color.accentColor.opacity(0.2) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .focused($isFocused)
    }
}

/// Non-focusable informational row (for display-only items like Documentation URL, Version)
struct TVSettingsInfoRow: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 20) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundColor(TVColors.textSecondary.opacity(0.6))
                .frame(width: 40)

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundColor(TVColors.textSecondary)

                Text(subtitle)
                    .font(.system(size: 18))
                    .foregroundColor(TVColors.textSecondary.opacity(0.7))
            }

            Spacer()
        }
        .padding(.vertical, 10)
    }
}

struct TVChangeServerAlert: View {
    @ObservedObject var viewModel: ViewModel

    private enum FocusedButton {
        case cancel, confirm
    }

    @FocusState private var focusedButton: FocusedButton?
    @State private var lastFocusedButton: FocusedButton = .cancel

    var body: some View {
        ZStack {
            // Dimmed background
            Color.black.opacity(0.7)
                .ignoresSafeArea()

            // Alert box
            VStack(spacing: 40) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.orange)

                Text("Change Server?")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundColor(TVColors.textAlert)

                Text("This will disconnect from the current server and erase local configuration.")
                    .font(.system(size: 24))
                    .foregroundColor(TVColors.textAlert)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 500)

                HStack(spacing: 40) {
                    // Cancel button
                    Button(action: {
                        viewModel.showChangeServerAlert = false
                    }) {
                        Text("Cancel")
                            .font(.system(size: 24))
                            .foregroundColor(.white)
                            .padding(.horizontal, 50)
                            .padding(.vertical, 16)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.white.opacity(0.5), lineWidth: 2)
                            )
                    }
                    .buttonStyle(.plain)
                    .focused($focusedButton, equals: .cancel)

                    // Confirm button
                    Button(action: {
                        viewModel.close()
                        viewModel.clearDetails()
                        viewModel.showChangeServerAlert = false
                        viewModel.navigateToServerView = true
                    }) {
                        Text("Confirm")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 50)
                            .padding(.vertical, 16)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.red)
                            )
                    }
                    .buttonStyle(.plain)
                    .focused($focusedButton, equals: .confirm)
                }
                .focusSection()
            }
            .padding(60)
            .background(
                RoundedRectangle(cornerRadius: 30)
                    .fill(TVColors.bgSideDrawer)
            )
        }
        .onAppear {
            focusedButton = .cancel
        }
        .onChange(of: focusedButton) { oldValue, newValue in
            _ = oldValue  // Suppress unused warning
            if let newValue = newValue {
                lastFocusedButton = newValue
            } else {
                // Focus escaped - pull it back
                focusedButton = lastFocusedButton
            }
        }
    }
}

struct TVRosenpassChangedAlert: View {
    @ObservedObject var viewModel: ViewModel

    private enum FocusedButton {
        case later, reconnect
    }

    @FocusState private var focusedButton: FocusedButton?
    @State private var lastFocusedButton: FocusedButton = .later

    var body: some View {
        ZStack {
            // Dimmed background
            Color.black.opacity(0.7)
                .ignoresSafeArea()

            // Alert box
            VStack(spacing: 40) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 60))
                    .foregroundColor(.blue)

                Text("Reconnect Required")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundColor(TVColors.textAlert)

                Text("Rosenpass settings have changed. Reconnect to apply the new security settings.")
                    .font(.system(size: 24))
                    .foregroundColor(TVColors.textAlert)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 500)

                HStack(spacing: 40) {
                    // Later button
                    Button(action: {
                        viewModel.showRosenpassChangedAlert = false
                    }) {
                        Text("Later")
                            .font(.system(size: 24))
                            .foregroundColor(.white)
                            .padding(.horizontal, 50)
                            .padding(.vertical, 16)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.white.opacity(0.5), lineWidth: 2)
                            )
                    }
                    .buttonStyle(.plain)
                    .focused($focusedButton, equals: .later)

                    // Reconnect button
                    Button(action: {
                        viewModel.showRosenpassChangedAlert = false
                        viewModel.close()
                        // Small delay before reconnecting to allow disconnect to complete
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            viewModel.connect()
                        }
                    }) {
                        Text("Reconnect")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 50)
                            .padding(.vertical, 16)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.blue)
                            )
                    }
                    .buttonStyle(.plain)
                    .focused($focusedButton, equals: .reconnect)
                }
                .focusSection()
            }
            .padding(60)
            .background(
                RoundedRectangle(cornerRadius: 30)
                    .fill(TVColors.bgSideDrawer)
            )
        }
        .onAppear {
            focusedButton = .reconnect
        }
        .onChange(of: focusedButton) { oldValue, newValue in
            _ = oldValue  // Suppress unused warning
            if let newValue = newValue {
                lastFocusedButton = newValue
            } else {
                // Focus escaped - pull it back
                focusedButton = lastFocusedButton
            }
        }
    }
}

struct TVSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        TVSettingsView()
            .environmentObject(ViewModel())
    }
}

#endif


