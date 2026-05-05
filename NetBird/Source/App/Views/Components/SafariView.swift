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
    let didFinish: () -> Void

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

        init(_ parent: SafariView) {
            self.parent = parent
        }

        func startSession(from viewController: UIViewController) {
            // The NetBird SDK uses a PKCE flow with an http://localhost redirect URI.
            // ASWebAuthenticationSession intercepts that navigation before the browser
            // follows it, so "http" works as a callback scheme in practice.
            // A proper long-term fix requires the SDK to expose a custom-scheme
            // redirect URI (e.g. "netbird://") for mobile OAuth flows.
            let completionHandler: ASWebAuthenticationSession.CompletionHandler = { [weak self] callbackURL, error in
                guard let self else { return }

                DispatchQueue.main.async {
                    if let callbackURL = callbackURL {
                        print("Auth callback URL: \(callbackURL.absoluteString)")
                    }
                    if let error = error as? ASWebAuthenticationSessionError,
                       error.code == .canceledLogin {
                        print("User cancelled login")
                    }
                    self.parent.isPresented = false
                    self.parent.didFinish()
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
