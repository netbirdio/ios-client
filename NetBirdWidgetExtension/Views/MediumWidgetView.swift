import SwiftUI
import WidgetKit

struct MediumWidgetView: View {
    let entry: VPNStatusEntry

    var body: some View {
        HStack(spacing: 12) {
            Image("logo-onboarding")
                .resizable()
                .scaledToFit()
                .frame(width: 56, height: 56)

            connectionInfo
                .frame(maxWidth: .infinity)

            if #available(iOS 17.0, *) {
                WidgetActionButton(entry: entry) {
                    transitionIndicator
                } label: { isConnected in
                    iconLabel(isConnected: isConnected)
                }
            } else if let url = entry.fallbackDeepLink {
                Link(destination: url) {
                    iconLabel(isConnected: entry.isConnected)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var connectionInfo: some View {
        VStack(alignment: .center, spacing: 4) {
            StatusIndicator(status: entry.status, fontSize: 16)

            if entry.isConnected && !entry.ip.isEmpty {
                Text(entry.ip)
                    .font(.system(size: 13, design: .monospaced))
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
        .accessibilityLabel(isConnected ? "Disconnect VPN" : "Connect VPN")
        .accessibilityValue(isConnected ? "On" : "Off")
        .accessibilityAddTraits(.isButton)
    }
}
