//
//  SafariView.swift
//  NetBird
//
//  iOS-only: runs the interactive OAuth/SSO login in ASWebAuthenticationSession —
//  the system authentication session, i.e. an external user-agent in the sense of
//  RFC 8252. The page runs in Safari's own process, outside the app's reach, which
//  is what keeps IdP-side features working: Google refuses OAuth in embedded
//  webviews (disallowed_useragent), passkeys/WebAuthn and hardware security keys
//  need a Safari-class agent, and enterprise policies (Okta, Entra conditional
//  access) may block embedded webviews.
//
//  The session is NOT ephemeral: it shares Safari's cookie jar, so the IdP's
//  trusted-device cookie survives and a re-login does not re-prompt for the second
//  factor. That single jar is shared by every profile, so profile isolation is
//  enforced on the request instead — the adapter adds prompt=select_account when a
//  login targets a different profile than the last authenticated one.
//

import SwiftUI

// Safari is only available on iOS
#if os(iOS)
import AuthenticationServices

/// How the login browser ended. The session cannot report whether the login as a
/// whole succeeded — the OAuth code is only the first half, the SDK still has to
/// exchange it and register with the management server — so the caller resolves
/// the final outcome through the SDK's callbacks.
enum LoginBrowserOutcome {
    /// The session captured the loopback redirect itself instead of letting the
    /// browser follow it. The URL carries the authorization code and has been
    /// replayed to the SDK's local server, so the flow continues.
    case redirectCaptured
    /// The browser was dismissed. Either the user cancelled, or they closed the
    /// SDK's success page after the redirect already went through — the two are
    /// indistinguishable here.
    case closed
    /// The session itself failed (could not present, or an OAuth error came back).
    case failed(Error)
}

struct SafariView: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let url: URL
    /// True starts the session with an empty cookie jar. Set for profiles whose
    /// account conflicts with the one the shared session holds — the only reliable
    /// way to reach a different account when the IdP ignores both login_hint and
    /// prompt=select_account.
    let prefersEphemeralSession: Bool
    let didFinish: (LoginBrowserOutcome) -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        let vc = UIViewController()
        // Start the auth session after the VC is presented
        DispatchQueue.main.async {
            context.coordinator.startSession(from: vc)
        }
        return vc
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: UIViewController, coordinator: Coordinator) {
        // Programmatic teardown (e.g. the login was aborted elsewhere): the session
        // presents its own window, which outlives this hosting VC unless cancelled.
        coordinator.cancelSession()
    }

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
            let completionHandler: ASWebAuthenticationSession.CompletionHandler = { [weak self] callbackURL, error in
                guard let self else { return }

                let outcome: LoginBrowserOutcome
                if let callbackURL {
                    // The session matched the loopback redirect and swallowed it, so
                    // the SDK's local HTTP server never saw the authorization code.
                    // Replay the request to hand the code over; without this the PKCE
                    // flow would wait until it expires. Harmless when the browser
                    // already delivered it — the SDK's server is gone by then and the
                    // request simply fails.
                    Self.replayToLoopback(callbackURL)
                    outcome = .redirectCaptured
                } else if let error = error as? ASWebAuthenticationSessionError,
                          error.code == .canceledLogin {
                    outcome = .closed
                } else if let error {
                    outcome = .failed(error)
                } else {
                    outcome = .closed
                }

                DispatchQueue.main.async {
                    self.session = nil
                    self.parent.isPresented = false
                    self.parent.didFinish(outcome)
                }
            }

            // The SDK's PKCE flow uses a loopback redirect (RFC 8252 §7.3): the
            // authorization code arrives at an HTTP server the SDK runs on
            // 127.0.0.1. That server is the primary path and needs no interception —
            // the browser simply follows the redirect to it, and this session then
            // ends via .closed when the user dismisses the SDK's success page.
            //
            // A session must still declare a callback, and "http" is the closest
            // match for that redirect. Should the session capture the navigation
            // instead of letting the browser follow it, the completion handler
            // replays the URL to the same local server, so the code still arrives.
            // Neither path leaves the flow hanging: resolveLoginAfterBrowserClose
            // probes the loopback listener and resolves the login either way.
            //
            // Apple intends this API for custom schemes or (iOS 17.4+) HTTPS
            // host/path callbacks. Moving to either would mean the management server
            // issuing a different redirect URI — a core/server change, not one the
            // app can make on its own.
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

            // Non-ephemeral: shares Safari's cookie jar so the IdP's trusted-device
            // cookie survives between logins and the second factor is not re-prompted
            // on every re-login. Cross-profile isolation is enforced by the
            // prompt=select_account the adapter adds when the profile changes.
            session.prefersEphemeralWebBrowserSession = parent.prefersEphemeralSession
            session.presentationContextProvider = self
            self.session = session
            session.start()
        }

        /// Dismisses the session UI. Safe to call after it already completed.
        func cancelSession() {
            session?.cancel()
            session = nil
        }

        /// Hands an intercepted authorization code to the SDK's loopback server.
        private static func replayToLoopback(_ callbackURL: URL) {
            var request = URLRequest(url: callbackURL)
            request.timeoutInterval = 10
            URLSession.shared.dataTask(with: request).resume()
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
