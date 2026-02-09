import SwiftUI

// MARK: - Internet Connection Status
struct InternetStatusView: View {
    @EnvironmentObject var viewModel: ViewModel

    private var isInternetConnected: Bool {
        viewModel.isInternetConnected
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isInternetConnected ? Color.green : Color.red)
                .frame(width: 10, height: 10)

            Text(isInternetConnected ? "Connected" : "Disconnected")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(Color("TextSecondary"))
        }
    }
}
