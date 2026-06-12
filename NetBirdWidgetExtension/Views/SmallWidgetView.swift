import SwiftUI
import WidgetKit

struct SmallWidgetView: View {
    let entry: VPNStatusEntry

    var body: some View {
        VStack(spacing: 8) {
            Image("logo-onboarding")
                .resizable()
                .scaledToFit()
                .frame(width: 65, height: 65)

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
        pillLabel(isConnected: false)
    }

    private func pillLabel(isConnected: Bool) -> some View {
        ZStack(alignment: isConnected ? .trailing : .leading) {
            Capsule()
                .fill(isConnected ? Color.netbirdOrange : Color(.systemGray3))
            Circle()
                .fill(Color.white)
                .shadow(color: .black.opacity(0.2), radius: 2, x: 0, y: 1)
                .padding(3)
        }
        .frame(width: 54, height: 30)
    }
}
