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
    /// Note: with the NetBird PKCE loopback flow the completion fires with a nil
    /// callbackURL even on success — the loopback redirect is consumed by the Go HTTP
    /// server, not the auth session — so the caller must determine success from the
    /// SDK's login callback, not from this handler.
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

            // An ephemeral session hands the IdP an empty cookie jar on every login.
            // Keycloak's login theme reacts to that by starting the session poll in
            // authChecker.js — it only skips it when a KEYCLOAK_SESSION cookie is
            // already present ("if (initialSession) return"). That poll races the
            // redirect carrying the authorization code and bounces the browser to
            // /login-actions/restart, which answers ALREADY_LOGGED_IN and fails the
            // login with authentication_expired. Safari on iOS never fires
            // beforeunload (WebKit bug 219102), so Keycloak's own safeguard against
            // that race never applies, and every login becomes a race against a
            // two-second timer.
            //
            // Persisting cookies avoids that, but it also means a logout no longer
            // clears the IdP session — which is what keeps profiles signed into
            // different accounts apart. So keep the ephemeral session exactly where it
            // still buys something: when the server does not already force a fresh
            // authentication. With prompt=login or max_age=0 the IdP re-authenticates
            // regardless of any live session, so the empty jar protects nothing and
            // only costs reliability.
            session.prefersEphemeralWebBrowserSession = !parent.url.forcesReauthentication
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

private extension URL {
    /// Whether this authorization request asks the IdP to authenticate the user afresh,
    /// ignoring any existing session.
    ///
    /// The SDK adds `prompt=login` or `max_age=0` according to the login flag the
    /// management server sends (`LoginFlagPromptLogin` by default), so the request URL
    /// already carries the answer and nothing needs plumbing through the SDK.
    var forcesReauthentication: Bool {
        guard let items = URLComponents(url: self, resolvingAgainstBaseURL: false)?.queryItems else {
            return false
        }
        return items.contains { item in
            (item.name == "prompt" && item.value == "login") || (item.name == "max_age" && item.value == "0")
        }
    }
}

#endif
