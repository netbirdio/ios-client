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

private struct TVColors {
    static var textPrimary: Color {
        UIColor(named: "TextPrimary") != nil ? Color("TextPrimary") : .primary
    }
    static var textSecondary: Color {
        UIColor(named: "TextSecondary") != nil ? Color("TextSecondary") : .secondary
    }
    static var textAlert: Color {
        UIColor(named: "TextAlert") != nil ? Color("TextAlert") : .white
    }
    static var bgMenu: Color {
        UIColor(named: "BgMenu") != nil ? Color("BgMenu") : Color(white: 0.1)
    }
    static var bgPrimary: Color {
        UIColor(named: "BgPrimary") != nil ? Color("BgPrimary") : Color(white: 0.15)
    }
    static var bgSideDrawer: Color {
        UIColor(named: "BgSideDrawer") != nil ? Color("BgSideDrawer") : Color(white: 0.2)
    }
}

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
                                        set: { viewModel.setRosenpassEnabled(enabled: $0) }
                                    )
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

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: { isOn.toggle() }) {
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

                // Custom toggle for better TV visibility
                ZStack {
                    Capsule()
                        .fill(isOn ? Color.green : Color.gray.opacity(0.3))
                        .frame(width: 70, height: 40)

                    Circle()
                        .fill(Color.white)
                        .frame(width: 32, height: 32)
                        .offset(x: isOn ? 15 : -15)
                        .animation(.easeInOut(duration: 0.2), value: isOn)
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
    
    @FocusState private var confirmFocused: Bool
    @FocusState private var cancelFocused: Bool
    
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
                    .focused($cancelFocused)
                    
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
                    .focused($confirmFocused)
                }
            }
            .padding(60)
            .background(
                RoundedRectangle(cornerRadius: 30)
                    .fill(TVColors.bgSideDrawer)
            )
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


