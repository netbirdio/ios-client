//
//  TVMockData.swift
//  NetBird
//
//  Debug helper for cycling through connection states
//  without requiring a real VPN connection.
//  Only compiled in DEBUG builds.
//

import SwiftUI

#if os(tvOS)
#if DEBUG

/// Auto-cycles the ViewModel through all connection states every 5 seconds.
struct TVDebugStateOverlay: View {
    @EnvironmentObject var viewModel: ViewModel

    private let states = ["Disconnected", "Connecting...", "Connected", "Disconnecting..."]

    @State private var currentIndex = 0

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Text(states[currentIndex])
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(TVColors.textSecondary.opacity(0.6))
                    .padding(.bottom, 12)
                    .padding(.trailing, 30)
            }
        }
        .allowsHitTesting(false)
        .onAppear { cycleState() }
    }

    private func cycleState() {
        let newState = states[currentIndex]
        viewModel.extensionStateText = newState

        switch newState {
        case "Connected":
            viewModel.fqdn = "device.netbird.cloud"
            viewModel.ip = "100.64.0.42"
        case "Connecting...", "Disconnecting...":
            viewModel.fqdn = "device.netbird.cloud"
            viewModel.ip = ""
        default:
            viewModel.fqdn = ""
            viewModel.ip = ""
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            currentIndex = (currentIndex + 1) % states.count
            cycleState()
        }
    }
}

#endif // DEBUG
#endif // os(tvOS)
