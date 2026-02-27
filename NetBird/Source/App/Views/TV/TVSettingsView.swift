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
    @State private var showPreSharedKeyAlert = false
    @State private var showDocsQRCode = false

    var body: some View {
        ZStack {
            TVGradientBackground()

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

                        TVSettingsSection(title: "Security") {
                            TVSettingsRow(
                                icon: "key.fill",
                                title: "Pre-Shared Key",
                                subtitle: viewModel.presharedKeySecure ? "Configured" : "Not configured",
                                action: { showPreSharedKeyAlert = true }
                            )
                        }

                        TVSettingsSection(title: "Info") {
                            TVSettingsRow(
                                icon: "qrcode.viewfinder",
                                title: "Documentation",
                                subtitle: "Scan QR code to visit docs.netbird.io",
                                action: { showDocsQRCode = true }
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
            // Load settings from storage to sync UI with actual values
            viewModel.loadRosenpassSettings()
            viewModel.loadPreSharedKey()
        }
        .sheet(isPresented: $showDocsQRCode) {
            TVQRCodeSheet(
                url: "https://docs.netbird.io",
                title: "Documentation",
                subtitle: "Scan this QR code to visit our docs"
            )
        }
        .fullScreenCover(isPresented: $showPreSharedKeyAlert) {
            TVPreSharedKeyAlert(
                viewModel: viewModel,
                isPresented: $showPreSharedKeyAlert
            )
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
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(TVColors.textPrimary.opacity(0.7))
                .tracking(2)

            VStack(spacing: 4) {
                content()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.white.opacity(0.04))
            )
        }
    }
}

/// Suppresses the default tvOS focus highlight so only our custom style is visible.
struct TVSettingsButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(configuration.isPressed ? -0.1 : 0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
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
                    .foregroundColor(isFocused ? .black : .accentColor)
                    .frame(width: 40)

                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundColor(isFocused ? .black : TVColors.textPrimary)

                    Text(subtitle)
                        .font(.system(size: 18))
                        .foregroundColor(isFocused ? .black.opacity(0.6) : TVColors.textSecondary)
                }

                Spacer()

                if action != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 20))
                        .foregroundColor(isFocused ? .black.opacity(0.5) : TVColors.textSecondary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isFocused ? Color.white : Color.clear)
            )
        }
        .buttonStyle(TVSettingsButtonStyle())
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
                    .foregroundColor(isDisabled ? TVColors.textSecondary.opacity(0.6) : (isFocused ? .black : .accentColor))
                    .frame(width: 40)

                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundColor(isDisabled ? TVColors.textSecondary.opacity(0.6) : (isFocused ? .black : TVColors.textPrimary))

                    Text(subtitle)
                        .font(.system(size: 18))
                        .foregroundColor(isDisabled ? TVColors.textSecondary.opacity(0.5) : (isFocused ? .black.opacity(0.6) : TVColors.textSecondary))
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
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isFocused && !isDisabled ? Color.white : Color.clear)
            )
        }
        .buttonStyle(TVSettingsButtonStyle())
        .focused($isFocused)
    }
}

/// Focusable informational row (for display-only items like Documentation URL, Version).
/// Must be focusable so tvOS ScrollView can scroll to the Info section.
struct TVSettingsInfoRow: View {
    let icon: String
    let title: String
    let subtitle: String

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: {}) {
            HStack(spacing: 20) {
                Image(systemName: icon)
                    .font(.system(size: 28))
                    .foregroundColor(isFocused ? .black.opacity(0.5) : TVColors.textSecondary)
                    .frame(width: 40)

                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundColor(isFocused ? .black : TVColors.textPrimary)

                    Text(subtitle)
                        .font(.system(size: 18))
                        .foregroundColor(isFocused ? .black.opacity(0.6) : TVColors.textSecondary)
                }

                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isFocused ? Color.white : Color.clear)
            )
        }
        .buttonStyle(TVSettingsButtonStyle())
        .focused($isFocused)
    }
}

/// Reusable button for TV alert dialogs with proper focus styling.
/// Text turns dark when focused to remain readable against the light highlight.
struct TVAlertButton: View {
    enum Style {
        case outlined
        case filled(Color)
    }

    let title: String
    let style: Style
    let isFocused: Bool
    let action: () -> Void
    var isSemibold: Bool = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 24, weight: isSemibold || isFilled ? .semibold : .regular))
                .foregroundColor(isFocused ? .black : .white)
                .padding(.horizontal, isFilled ? 50 : 40)
                .padding(.vertical, 16)
                .background(backgroundView)
        }
        .buttonStyle(.plain)
    }

    private var isFilled: Bool {
        if case .filled = style { return true }
        return false
    }

    @ViewBuilder
    private var backgroundView: some View {
        switch style {
        case .outlined:
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.5), lineWidth: 2)
        case .filled(let color):
            RoundedRectangle(cornerRadius: 12)
                .fill(color)
        }
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
                    TVAlertButton(
                        title: "Cancel",
                        style: .outlined,
                        isFocused: focusedButton == .cancel,
                        action: { viewModel.showChangeServerAlert = false }
                    )
                    .focused($focusedButton, equals: .cancel)

                    // Confirm button
                    TVAlertButton(
                        title: "Confirm",
                        style: .filled(Color.red),
                        isFocused: focusedButton == .confirm,
                        action: {
                            viewModel.close()
                            viewModel.clearDetails()
                            viewModel.showChangeServerAlert = false
                            viewModel.navigateToServerView = true
                        }
                    )
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
                    TVAlertButton(
                        title: "Later",
                        style: .outlined,
                        isFocused: focusedButton == .later,
                        action: { viewModel.showRosenpassChangedAlert = false }
                    )
                    .focused($focusedButton, equals: .later)

                    // Reconnect button
                    TVAlertButton(
                        title: "Reconnect",
                        style: .filled(Color.blue),
                        isFocused: focusedButton == .reconnect,
                        action: {
                            viewModel.showRosenpassChangedAlert = false
                            viewModel.close()
                            // Small delay before reconnecting to allow disconnect to complete
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                viewModel.connect()
                            }
                        }
                    )
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

struct TVPreSharedKeyAlert: View {
    @ObservedObject var viewModel: ViewModel
    @Binding var isPresented: Bool
    @State private var keyText: String = ""
    @State private var isInvalid: Bool = false

    var body: some View {
        ZStack {
            // Dimmed background
            Color.black.opacity(0.7)
                .ignoresSafeArea()

            // Alert box
            VStack(spacing: 30) {
                Image(systemName: "key.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.orange)

                Text("Pre-Shared Key")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundColor(TVColors.textPrimary)

                Text("Enter a 32-byte base64-encoded key. You will only communicate with peers that use the same key.")
                    .font(.system(size: 22))
                    .foregroundColor(TVColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 600)

                // Text field for key input
                TextField("Pre-shared key", text: $keyText)
                    .font(.system(size: 24))
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.white.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(isInvalid ? Color.red : Color.white.opacity(0.12), lineWidth: isInvalid ? 2 : 1)
                    )
                    .frame(maxWidth: 600)
                    .onChange(of: keyText) { _, newValue in
                        isInvalid = !isValidBase64Key(newValue)
                    }

                if isInvalid && !keyText.isEmpty {
                    Text("Invalid key - must be 32-byte base64 encoded")
                        .font(.system(size: 18))
                        .foregroundColor(.red)
                }

                HStack(spacing: 30) {
                    // Cancel button
                    TVPreSharedKeyButton(
                        title: "Cancel",
                        color: nil,
                        action: { isPresented = false }
                    )

                    // Remove button (only if key is configured)
                    if viewModel.presharedKeySecure {
                        TVPreSharedKeyButton(
                            title: "Remove",
                            color: .red,
                            action: {
                                viewModel.removePreSharedKey()
                                isPresented = false
                            }
                        )
                    }

                    // Save button
                    TVPreSharedKeyButton(
                        title: "Save",
                        color: (isInvalid || keyText.isEmpty) ? .gray : .green,
                        action: {
                            if !isInvalid && !keyText.isEmpty {
                                viewModel.presharedKey = keyText
                                viewModel.updatePreSharedKey()
                                isPresented = false
                            }
                        }
                    )
                }
            }
            .padding(60)
            .background(
                RoundedRectangle(cornerRadius: 30)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.14, green: 0.14, blue: 0.24),
                                Color(red: 0.08, green: 0.08, blue: 0.14)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 30)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
        }
        .focusSection()
        .onExitCommand {
            isPresented = false
        }
        .onAppear {
            // Pre-fill with current key if editing
            if viewModel.presharedKeySecure {
                keyText = viewModel.presharedKey
            }
        }
    }

    private func isValidBase64Key(_ input: String) -> Bool {
        if input.isEmpty { return true }
        guard let data = Data(base64Encoded: input) else { return false }
        return data.count == 32
    }
}

struct TVSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        TVSettingsView()
            .environmentObject(ViewModel())
    }
}

#endif


