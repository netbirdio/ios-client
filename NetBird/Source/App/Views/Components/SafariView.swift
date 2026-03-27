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
            // Use "http" callback scheme to intercept the localhost redirect
            let session = ASWebAuthenticationSession(
                url: parent.url,
                callbackURLScheme: "http"
            ) { [weak self] callbackURL, error in
                guard let self = self else { return }

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

            // Ephemeral = no shared cookies, fresh login every time
            session.prefersEphemeralWebBrowserSession = true
            session.presentationContextProvider = self
            self.session = session
            session.start()
        }

        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            // Return the key window as the presentation anchor
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first(where: { $0.isKeyWindow }) ?? UIWindow()
        }
    }
}
#endif
