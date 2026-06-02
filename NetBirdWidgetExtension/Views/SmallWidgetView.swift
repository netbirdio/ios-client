import SwiftUI
import WidgetKit

struct SmallWidgetView: View {
    let entry: VPNStatusEntry

    var body: some View {
        VStack(spacing: 8) {
            Image("netbird-logo-menu")
                .resizable()
                .scaledToFit()
                .frame(width: 75, height: 75)

            StatusIndicator(status: entry.status)

            if #available(iOS 17.0, *) {
                WidgetActionButton(entry: entry) {
                    transitionPill()
                } label: { isConnected in
                    pillLabel(isConnected: isConnected)
                }
            } else if let url = entry.fallbackDeepLink {
                Link(destination: url) {
                    pillLabel(isConnected: entry.isConnected)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func transitionPill() -> some View {
        ZStack {
            Capsule()
                .fill(Color.orange.opacity(0.85))
            Circle()
                .fill(Color.white.opacity(0.9))
                .shadow(color: .black.opacity(0.15), radius: 2, x: 0, y: 1)
                .padding(3)
                .overlay(
                    ProgressView()
                        .scaleEffect(0.45)
                        .tint(.orange)
                )
        }
        .frame(width: 54, height: 30)
    }

    private func pillLabel(isConnected: Bool) -> some View {
        ZStack(alignment: isConnected ? .trailing : .leading) {
            Capsule()
                .fill(isConnected ? Color.green : Color.red)
            Circle()
                .fill(Color.white)
                .shadow(color: .black.opacity(0.2), radius: 2, x: 0, y: 1)
                .padding(3)
        }
        .frame(width: 54, height: 30)
    }
}
