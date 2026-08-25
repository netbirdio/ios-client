//
//  SafariView.swift
//  NetBird
//
//  iOS-only: Wraps ASWebAuthenticationSession for in-app web authentication.
//  Uses ephemeral session so each login starts fresh (no shared cookies),
//  which is required for multi-profile support.
//

import SwiftUI

// Safari is only available on iOS
#if os(iOS)
import AuthenticationServices

struct SafariView: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let url: URL
    /// Called when the web auth session ends (success, user cancel, or error).
    ///
    /// Note: with the NetBird PKCE loopback flow the completion fires with a nil
    /// callbackURL even on success — the loopback redirect is consumed by the Go HTTP
    /// server, not the auth session — so the caller must determine success from the
    /// SDK's login callback, not from this handler.
    ///
    /// - Parameter interruptedByBackgrounding: true when the app was sent to the
    ///   background while the session was open. iOS then ends the session with
    ///   `canceledLogin`, which is indistinguishable from the user tapping Cancel,
    ///   even though the login is still very much in progress. This happens on every
    ///   login that requires leaving the app — switching to an authenticator app to
    ///   approve a push, for instance. Treating it as a cancellation tears down the
    ///   loopback server that the IdP redirect is about to arrive at.
    let didFinish: (_ interruptedByBackgrounding: Bool) -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        let vc = UIViewController()
        // Start the auth session after the VC is presented
        DispatchQueue.main.async {
            context.coordinator.startSession(from: vc)
        }
        return vc
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, ASWebAuthenticationPresentationContextProviding {
        let parent: SafariView
        private var session: ASWebAuthenticationSession?
        private var backgroundObserver: NSObjectProtocol?
        private var wentToBackground = false

        init(_ parent: SafariView) {
            self.parent = parent
        }

        /// Drops the backgrounding observer if the coordinator goes away before the
        /// auth session completes.
        deinit {
            if let backgroundObserver {
                NotificationCenter.default.removeObserver(backgroundObserver)
            }
        }

        /// Presents the web authentication session for the login URL.
        ///
        /// - Parameter viewController: the just-presented controller the session is
        ///   started from, once it is part of the window hierarchy.
        func startSession(from viewController: UIViewController) {
            // The NetBird SDK uses a PKCE flow with an http://localhost redirect URI.
            // ASWebAuthenticationSession intercepts that navigation before the browser
            // follows it, so "http" works as a callback scheme in practice.
            // A proper long-term fix requires the SDK to expose a custom-scheme
            // redirect URI (e.g. "netbird://") for mobile OAuth flows.
            // iOS ends the session with .canceledLogin when the app is backgrounded,
            // so remember whether that happened before the completion fires.
            backgroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.wentToBackground = true
            }

            let completionHandler: ASWebAuthenticationSession.CompletionHandler = { [weak self] callbackURL, error in
                guard let self else { return }

                DispatchQueue.main.async {
                    if let callbackURL = callbackURL {
                        print("Auth callback URL: \(callbackURL.absoluteString)")
                    }
                    if let error = error as? ASWebAuthenticationSessionError,
                       error.code == .canceledLogin {
                        print(self.wentToBackground
                              ? "Auth session ended after the app was backgrounded"
                              : "User cancelled login")
                    }
                    if let backgroundObserver = self.backgroundObserver {
                        NotificationCenter.default.removeObserver(backgroundObserver)
                        self.backgroundObserver = nil
                    }
                    self.parent.isPresented = false
                    self.parent.didFinish(self.wentToBackground)
                }
            }

            let session: ASWebAuthenticationSession
            if #available(iOS 17.4, *) {
                session = ASWebAuthenticationSession(
                    url: parent.url,
                    callback: .customScheme("http"),
                    completionHandler: completionHandler
                )
            } else {
                session = ASWebAuthenticationSession(
                    url: parent.url,
                    callbackURLScheme: "http",
                    completionHandler: completionHandler
                )
            }

            // Ephemeral = no shared cookies, fresh login every time
            session.prefersEphemeralWebBrowserSession = true
            session.presentationContextProvider = self
            self.session = session
            session.start()
        }

        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            guard let keyWindow = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap({ $0.windows })
                .first(where: { $0.isKeyWindow })
            else {
                assertionFailure("No key window found — auth session may fail to present")
                return UIWindow()
            }
            return keyWindow
        }
    }
}
#endif
