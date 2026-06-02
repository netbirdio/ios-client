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
                .frame(width: 100)
            } else if let url = entry.fallbackDeepLink {
                Link(destination: url) {
                    iconLabel(isConnected: entry.isConnected)
                }
                .frame(width: 100)
            }
        }
        .padding()
    }

    private var statusInfo: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image("netbird-logo-menu")
                .resizable()
                .scaledToFit()
                .frame(width: 75, height: 75)

            StatusIndicator(status: entry.status, fontSize: 14)

            if entry.isConnected && !entry.ip.isEmpty {
                Text(entry.ip)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            if entry.isConnected && !entry.fqdn.isEmpty {
                Text(entry.fqdn)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }

    private var transitionIndicator: some View {
        ZStack {
            Capsule()
                .fill(Color.orange.opacity(0.85))
            Circle()
                .fill(Color.white.opacity(0.9))
                .shadow(color: .black.opacity(0.15), radius: 2, x: 0, y: 1)
                .padding(3)
                .overlay(
                    ProgressView()
                        .scaleEffect(0.5)
                        .tint(.orange)
                )
        }
        .frame(width: 64, height: 36)
    }

    private func iconLabel(isConnected: Bool) -> some View {
        ZStack(alignment: isConnected ? .trailing : .leading) {
            Capsule()
                .fill(isConnected ? Color.green : Color.red)
            Circle()
                .fill(Color.white)
                .shadow(color: .black.opacity(0.2), radius: 2, x: 0, y: 1)
                .padding(3)
        }
        .frame(width: 64, height: 36)
    }
}
