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
                    ProgressView()
                        .scaleEffect(0.7)
                } label: { isConnected in
                    pillLabel(isConnected: isConnected)
                }
            } else if let url = entry.isConnected ? WidgetConstants.deepLinkDisconnect : WidgetConstants.deepLinkConnect {
                Link(destination: url) {
                    pillLabel(isConnected: entry.isConnected)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func pillLabel(isConnected: Bool) -> some View {
        Text(isConnected ? "Disconnect" : "Connect")
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(isConnected ? Color.red : Color.green)
            .cornerRadius(8)
    }
}
