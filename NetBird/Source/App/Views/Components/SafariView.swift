//
//  SafariView.swift
//  NetBird
//
//  iOS-only: Wraps SFSafariViewController for in-app web authentication.
//  tvOS does not have Safari, so it uses TVAuthView instead.
//

import SwiftUI

// Safari is only available on iOS
#if os(iOS)
import SafariServices

/// Presents Safari in-app for OAuth authentication flows.
/// Used to handle login redirects without leaving the app.
struct SafariView: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let url: URL
    let didFinish: () -> Void

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, SFSafariViewControllerDelegate {
        let parent: SafariView

        init(_ parent: SafariView) {
            self.parent = parent
        }

        func safariViewController(_ controller: SFSafariViewController, initialLoadDidRedirectTo URL: URL) {
            print("Url is: \(URL.absoluteString)")
            if isSuccessURL(URL.absoluteString) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    self.parent.isPresented = false
                    self.parent.didFinish()
                }
            }
        }
        
        func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
            parent.isPresented = false
            parent.didFinish()
        }
        
        func isSuccessURL(_ string: String) -> Bool {
            if string.isEmpty { return true }
            let pattern = "^(http|https)://(localhost:53000/\\?code=.*|[a-zA-Z0-9.-]+/device/success)$"
            let isMatch = string.range(of: pattern, options: .regularExpression, range: nil, locale: nil) != nil
            return isMatch
        }
    }
}
#endif
