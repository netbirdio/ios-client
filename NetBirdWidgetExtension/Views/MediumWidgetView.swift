import SwiftUI
import WidgetKit

struct MediumWidgetView: View {
    let entry: VPNStatusEntry

    var body: some View {
        HStack(spacing: 0) {
            statusInfo
                .frame(maxWidth: .infinity, alignment: .leading)

            if #available(iOS 17.0, *) {
                WidgetActionButton(entry: entry) {
                    transitionIndicator
                } label: { isConnected in
                    iconLabel(isConnected: isConnected)
                }
                .frame(width: 80)
            } else if let url = entry.fallbackDeepLink {
                Link(destination: url) {
                    iconLabel(isConnected: entry.isConnected)
                }
                .frame(width: 80)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var statusInfo: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image("logo-onboarding")
                .resizable()
                .scaledToFit()
                .frame(width: 56, height: 56)

            StatusIndicator(status: entry.status, fontSize: 16)

            if entry.isConnected && !entry.ip.isEmpty {
                Text(entry.ip)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var transitionIndicator: some View {
        iconLabel(isConnected: false)
    }

    private func iconLabel(isConnected: Bool) -> some View {
        ZStack(alignment: isConnected ? .trailing : .leading) {
            Capsule()
                .fill(isConnected ? Color.netbirdOrange : Color(.systemGray3))
            Circle()
                .fill(Color.white)
                .shadow(color: .black.opacity(0.2), radius: 2, x: 0, y: 1)
                .padding(3)
        }
        .frame(width: 64, height: 36)
    }
}
