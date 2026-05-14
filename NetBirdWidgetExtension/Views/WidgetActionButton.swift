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
        if entry.needsAppSetup && !entry.isConnected {
            // Login required or VPN not configured — open the app regardless of
            // any transitioning state so the user is never stuck on a spinner.
            openAppLink {
                label(false)
            }
        } else if entry.status.isTransitioning {
            transitionContent()
        } else {
            Button(intent: ToggleVPNIntent(action: entry.isConnected ? "disconnect" : "connect")) {
                label(entry.isConnected)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func openAppLink<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        let url = entry.loginRequired ? WidgetConstants.deepLinkLogin : WidgetConstants.deepLinkConnect
        if let url {
            Link(destination: url, label: content)
        } else {
            content()
        }
    }
}
