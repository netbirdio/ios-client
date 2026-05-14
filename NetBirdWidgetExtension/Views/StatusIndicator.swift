import SwiftUI

struct StatusIndicator: View {
    let status: WidgetVPNStatus
    var fontSize: CGFloat = 13

    var body: some View {
        HStack(spacing: 6) {
            if status.isTransitioning {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 8, height: 8)
            } else {
                Circle()
                    .fill(status.statusColor)
                    .frame(width: 8, height: 8)
            }

            Text(status.displayText)
                .font(.system(size: fontSize, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(1)
        }
    }
}
