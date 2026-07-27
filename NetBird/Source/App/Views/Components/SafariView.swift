//
//  SafariView.swift
//  NetBird
//
//  iOS-only: the in-app web-auth browser for interactive SSO login. One logic
//  for every profile, default included: persistent cookies scoped to the
//  profile (the IdP's trusted-device 2FA cookie survives, so a re-login skips
//  the OTP prompt) and auto-close shortly after the OAuth loopback response —
//  the behavior the pre-multi-profile SFSafariViewController version had,
//  now with per-profile isolation.
//

import SwiftUI

// Only used on iOS (tvOS logs in via TVAuthView's device-code flow)
#if os(iOS)
import WebKit

/// Login browser used by every profile. Persistent cookies and auto-close a few
/// seconds after the OAuth loopback redirect, with each profile's cookies in its
/// own persistent WKWebsiteDataStore — the IdP's trusted-device 2FA cookie
/// survives re-logins per profile while profiles stay fully isolated from one
/// another.
struct ProfileLoginWebView: View {
    @Binding var isPresented: Bool
    let profileName: String
    let url: URL
    /// `userCancelled` is true only for the explicit Cancel button. The auto-close
    /// after the loopback redirect passes false — at that point the login may
    /// STILL be completing on the SDK side (first-time profile registration can
    /// outlast the close grace), so the caller must not treat it as a cancel.
    let didFinish: (_ userCancelled: Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") {
                    isPresented = false
                    didFinish(true)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                Spacer()
            }
            .background(Color("BgMenu"))

            LoginWebViewRepresentable(
                url: url,
                storeIdentifier: Preferences.webStoreIdentifier(for: profileName),
                onSuccessRedirect: {
                    isPresented = false
                    didFinish(false)
                }
            )
        }
        .background(Color("BgMenu").ignoresSafeArea())
    }
}

private struct LoginWebViewRepresentable: UIViewRepresentable {
    let url: URL
    let storeIdentifier: UUID
    /// Called (on the main queue) shortly after the loopback response finished
    /// loading — i.e. once the token exchange is done. The management login may
    /// still be running; the caller defers to the SDK's result for that part.
    let onSuccessRedirect: () -> Void

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        if #available(iOS 17.0, *) {
            // Persistent, identifier-scoped store: this profile's cookies only.
            config.websiteDataStore = WKWebsiteDataStore(forIdentifier: storeIdentifier)
        } else {
            // Pre-iOS 17 has no per-identifier persistent stores. Fall back to an
            // isolated in-memory store — still fully isolated, but the trusted-device
            // cookie won't survive, so these users re-enter the OTP on each login.
            config.websiteDataStore = .nonPersistent()
        }
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        let parent: LoginWebViewRepresentable
        private var successURLSeen = false
        private var closeScheduled = false

        init(_ parent: LoginWebViewRepresentable) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if !successURLSeen,
               let url = navigationAction.request.url,
               Self.isSuccessURL(url.absoluteString) {
                successURLSeen = true
                // Don't log the URL itself — its query carries the OAuth
                // authorization code.
                print("Login success redirect detected (host: \(url.host ?? "?"))")
            }
            // Always allow — the loopback redirect must reach the SDK's local HTTP
            // server, which is what actually receives the authorization code.
            decisionHandler(.allow)
        }

        // Close only after the loopback RESPONSE arrived (the page finished
        // loading), not on a timer from when the request started: the SDK's local
        // server answers that request only once the token exchange is done, and
        // tearing the web view down earlier cancels the request — which cancels
        // the exchange itself and kills the login. After the response, only the
        // management login remains; the adapter starts the VPN when it completes,
        // so the window may close after a short glance at the success page.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            scheduleCloseIfNeeded()
        }

        // Post-success failures only (scheduleCloseIfNeeded guards on
        // successURLSeen): if the loopback request fails AFTER the redirect was
        // seen (e.g. the flow was already torn down server-side), close instead
        // of leaving the user on a blank page. Failures BEFORE the redirect are
        // deliberately ignored: WebKit reports benign NSURLErrorCancelled (-999)
        // whenever one navigation supersedes another mid-redirect-chain, so
        // reacting to pre-success failures would abort healthy logins. If the
        // IdP genuinely fails to load, the user backs out via Cancel.
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            scheduleCloseIfNeeded()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            scheduleCloseIfNeeded()
        }

        private func scheduleCloseIfNeeded() {
            guard successURLSeen, !closeScheduled else { return }
            closeScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self.parent.onSuccessRedirect()
            }
        }

        // Same success pattern the pre-multi-profile SFSafariViewController
        // version matched (minus its empty-string case, which cannot occur for
        // a WKNavigationAction URL).
        static func isSuccessURL(_ string: String) -> Bool {
            let pattern = "^(http|https)://(localhost:53000/\\?code=.*|[a-zA-Z0-9.-]+/device/success)$"
            return string.range(of: pattern, options: .regularExpression) != nil
        }
    }
}
#endif
