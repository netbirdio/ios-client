import SwiftUI
import AppIntents

/// Resolves what the widget's action area should show based on VPN state.
/// Extracts the shared transitioning / needsSetup / normal branching logic
/// so Small and Medium views stay focused on layout.
@available(iOS 17.0, *)
struct WidgetActionButton<TransitionContent: View, Label: View>: View {
    let entry: VPNStatusEntry
    let transitionContent: () -> TransitionContent
    let label: (_ isConnected: Bool) -> Label

    var body: some View {
        if entry.loginRequired && !entry.isConnected {
            // Login required — open the app immediately even during a transitioning
            // state so the user is never stuck on a spinner waiting for re-auth.
            openAppLink(url: WidgetConstants.deepLinkLogin) {
                label(false)
            }
        } else if entry.status.isTransitioning {
            transitionContent()
        } else if entry.needsAppSetup && !entry.isConnected {
            // VPN profile not configured yet — open the app for initial setup.
            openAppLink(url: WidgetConstants.deepLinkConnect) {
                label(false)
            }
        } else {
            Button(intent: ToggleVPNIntent(action: entry.isConnected ? "disconnect" : "connect")) {
                label(entry.isConnected)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func openAppLink<Content: View>(
        url: URL?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if let url {
            Link(destination: url, label: content)
        } else {
            content()
        }
    }
}
