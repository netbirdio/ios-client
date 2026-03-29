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
        VStack(spacing: 4) {
            ProgressView()
            Text(entry.status.displayText)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    private func iconLabel(isConnected: Bool) -> some View {
        let color: Color = isConnected ? .red : .green
        return VStack(spacing: 4) {
            Image(systemName: isConnected ? "stop.circle.fill" : "play.circle.fill")
                .font(.system(size: 32))
                .foregroundColor(color)

            Text(isConnected ? "Disconnect" : "Connect")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(color)
        }
    }
}
