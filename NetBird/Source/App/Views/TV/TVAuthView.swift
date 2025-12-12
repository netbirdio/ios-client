//
//  TVAuthView.swift
//  NetBird
//
//  Authentication view for tvOS.
//  Since Safari isn't available on Apple TV, we show users
//  a QR code and device code to enter on another device (phone/computer).
//
//  This is the "device code flow" pattern used by Netflix, YouTube, etc.
//

import SwiftUI
import CoreImage.CIFilterBuiltins

#if os(tvOS)

/// Displays authentication instructions for tvOS users.
/// Users scan a QR code or visit a URL on their phone/computer to complete sign-in.
struct TVAuthView: View {
    /// The URL users should visit to authenticate
    let loginURL: String

    /// The user code to display (from device auth flow)
    /// If nil, will try to extract from URL
    var userCode: String?

    /// Whether authentication is in progress
    @Binding var isPresented: Bool

    /// Called when user cancels authentication
    var onCancel: (() -> Void)?

    /// Called when authentication completes (detected via polling)
    var onComplete: (() -> Void)?

    /// Called when authentication fails (e.g., device code expires, server rejects)
    var onError: ((String) -> Void)?

    /// Reference to check login status (async - calls completion with true if login is complete)
    var checkLoginComplete: ((@escaping (Bool) -> Void) -> Void)?

    /// Reference to check for login errors (async - calls completion with error message or nil)
    var checkLoginError: ((@escaping (String?) -> Void) -> Void)?

    /// Polling timer to check if login completed
    @State private var pollTimer: Timer?

    /// QR code image generated from login URL
    @State private var qrCodeImage: UIImage?

    /// Error message to display if authentication fails
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            // Dark overlay background
            Color.black.opacity(0.9)
                .ignoresSafeArea()

            HStack(spacing: 80) {
                // Left Side - QR Code
                VStack(spacing: 30) {
                    Text("Scan to Sign In")
                        .font(.system(size: 36, weight: .bold))
                        .foregroundColor(.white)

                    // QR Code
                    if let qrImage = qrCodeImage {
                        Image(uiImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 280, height: 280)
                            .background(Color.white)
                            .cornerRadius(16)
                    } else {
                        // Placeholder while generating
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.white)
                            .frame(width: 280, height: 280)
                            .overlay(
                                ProgressView()
                                    .scaleEffect(2)
                            )
                    }

                    Text("Scan with your phone camera")
                        .font(.system(size: 24))
                        .foregroundColor(.gray)
                }
                .padding(50)
                .background(
                    RoundedRectangle(cornerRadius: 24)
                        .fill(Color.white.opacity(0.05))
                )

                // Divider
                Rectangle()
                    .fill(Color.white.opacity(0.2))
                    .frame(width: 2, height: 600)

                // Right Side - Device Code
                VStack(spacing: 40) {
                    // App logo
                    Image("netbird-logo-menu")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 200)

                    // Device code display
                    if let code = displayUserCode {
                        VStack(spacing: 20) {
                            Text("Device code:")
                                .font(.system(size: 28))
                                .foregroundColor(.gray)

                            Text(code)
                                .font(.system(size: 64, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                                .tracking(6)
                                .padding(.horizontal, 40)
                                .padding(.vertical, 20)
                                .background(
                                    RoundedRectangle(cornerRadius: 16)
                                        .fill(Color.accentColor.opacity(0.2))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 16)
                                                .stroke(Color.accentColor, lineWidth: 2)
                                        )
                                )
                        }
                    }

                    // Error message or loading indicator
                    if let error = errorMessage {
                        VStack(spacing: 15) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 36))
                                .foregroundColor(.orange)

                            Text(error)
                                .font(.system(size: 20))
                                .foregroundColor(.orange)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 400)
                        }
                        .padding(20)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.orange.opacity(0.1))
                        )
                        .padding(.top, 20)
                    } else {
                        HStack(spacing: 15) {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(1.2)

                            Text("Waiting for sign-in...")
                                .font(.system(size: 22))
                                .foregroundColor(.gray)
                        }
                        .padding(.top, 20)
                    }

                    // Cancel button
                    Button(action: {
                        pollTimer?.invalidate()
                        onCancel?()
                        isPresented = false
                    }) {
                        Text("Cancel")
                            .font(.system(size: 22))
                            .foregroundColor(.white)
                            .padding(.horizontal, 50)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.white.opacity(0.3), lineWidth: 2)
                            )
                    }
                    .buttonStyle(.plain)
                }
                .padding(50)
                .background(
                    RoundedRectangle(cornerRadius: 24)
                        .fill(Color.white.opacity(0.05))
                )
            }
            .padding(60)
        }
        .onAppear {
            generateQRCode()
            startPollingForCompletion()
        }
        .onDisappear {
            pollTimer?.invalidate()
        }
    }

    // Computed Properties

    /// The user code to display - prefers passed-in userCode, falls back to URL extraction
    private var displayUserCode: String? {
        if let code = userCode, !code.isEmpty {
            return code
        }
        return extractUserCode(from: loginURL)
    }

    // Helper Functions

    /// Generates a QR code image from the login URL
    private func generateQRCode() {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()

        filter.message = Data(loginURL.utf8)
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage else { return }

        // Scale up the QR code for better visibility
        let scale = 10.0
        let transform = CGAffineTransform(scaleX: scale, y: scale)
        let scaledImage = outputImage.transformed(by: transform)

        if let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) {
            qrCodeImage = UIImage(cgImage: cgImage)
        }
    }

    /// Extracts the user code from the URL (typically shown to users)
    private func extractUserCode(from url: String) -> String? {
        guard let urlObj = URL(string: url),
              let components = URLComponents(url: urlObj, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            return nil
        }

        // Look for user_code first (the human-readable code)
        // Then fall back to code parameter
        for item in queryItems {
            let name = item.name.lowercased()
            if name == "user_code" {
                return item.value
            }
        }

        // Fallback to generic code parameter
        for item in queryItems {
            let name = item.name.lowercased()
            if name == "code" {
                return item.value
            }
        }

        return nil
    }

    /// Starts polling to check if authentication completed
    private func startPollingForCompletion() {
        #if DEBUG
        print("TVAuthView: Starting polling for login completion")
        #endif
        pollTimer?.invalidate()

        // Capture the closures and bindings we need
        // SwiftUI structs are value types, so we capture these by value
        let checkComplete = self.checkLoginComplete
        let checkError = self.checkLoginError
        let onCompleteHandler = self.onComplete
        let onErrorHandler = self.onError

        // Schedule timer on main run loop to ensure it fires
        let timer = Timer(timeInterval: 2.0, repeats: true) { timer in
            #if DEBUG
            print("TVAuthView: Poll tick - checking login status via extension IPC...")
            #endif

            // First check for errors
            if let checkError = checkError {
                checkError { errorMsg in
                    DispatchQueue.main.async {
                        if let errorMsg = errorMsg {
                            #if DEBUG
                            print("TVAuthView: Login error detected: \(errorMsg)")
                            #endif
                            timer.invalidate()
                            onErrorHandler?(errorMsg)
                            // Don't auto-dismiss - let user see the error and cancel
                            return
                        }
                    }
                }
            }

            guard let checkComplete = checkComplete else {
                #if DEBUG
                print("TVAuthView: No checkLoginComplete closure provided")
                #endif
                return
            }

            checkComplete { isComplete in
                DispatchQueue.main.async {
                    #if DEBUG
                    print("TVAuthView: Login complete = \(isComplete)")
                    #endif
                    if isComplete {
                        #if DEBUG
                        print("TVAuthView: Login detected as complete, dismissing auth view")
                        #endif
                        timer.invalidate()
                        onCompleteHandler?()
                    }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer

        // Fire immediately once to check current status
        #if DEBUG
        print("TVAuthView: Performing initial login check...")
        #endif
        guard let checkComplete = checkComplete else {
            #if DEBUG
            print("TVAuthView: No checkLoginComplete closure provided")
            #endif
            return
        }
        checkComplete { isComplete in
            DispatchQueue.main.async {
                #if DEBUG
                print("TVAuthView: Initial check - login complete = \(isComplete)")
                #endif
                if isComplete {
                    #if DEBUG
                    print("TVAuthView: Login already complete, dismissing auth view")
                    #endif
                    onCompleteHandler?()
                }
            }
        }
    }
}

/// Preview provider for development
struct TVAuthView_Previews: PreviewProvider {
    static var previews: some View {
        TVAuthView(
            loginURL: "https://app.netbird.io/device?user_code=ABCD-1234",
            isPresented: .constant(true),
            checkLoginComplete: { completion in
                // Preview always returns false (not logged in)
                completion(false)
            }
        )
    }
}

#endif


