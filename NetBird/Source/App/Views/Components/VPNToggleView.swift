import SwiftUI

#if os(iOS)

struct VPNToggleView: View {
    let vpnState: VPNDisplayState
    let isLocked: Bool
    let onConnect: () -> Void
    let onDisconnect: () -> Void

    @State private var pulseOpacity: Double = 1.0
    // Optimistic override: set immediately on tap so thumb moves without waiting for OS
    @State private var optimisticIsOn: Bool? = nil

    // Use optimistic value while OS hasn't confirmed yet; fall back to real state
    private var isOn: Bool {
        optimisticIsOn ?? (vpnState == .connected || vpnState == .connecting)
    }

    // Pulse whenever the real state is transitioning OR we're waiting for OS confirmation
    private var isTransitioning: Bool {
        optimisticIsOn != nil || vpnState == .connecting || vpnState == .disconnecting
    }

    private let trackWidth: CGFloat = 120
    private let trackHeight: CGFloat = 65
    private var thumbDiameter: CGFloat { trackHeight - 8 }
    private var thumbTravel: CGFloat { (trackWidth - thumbDiameter) / 2 - 4 }

    var body: some View {
        ZStack {
            Capsule()
                .fill(isOn ? Color.orange : Color(white: 0.25))
                .opacity(pulseOpacity)
                .frame(width: trackWidth, height: trackHeight)
                .animation(.easeInOut(duration: 0.3), value: isOn)

            Circle()
                .fill(Color.white)
                .frame(width: thumbDiameter, height: thumbDiameter)
                .offset(x: isOn ? thumbTravel : -thumbTravel)
                .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)
                .animation(.spring(response: 0.38, dampingFraction: 0.75), value: isOn)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isLocked else { return }
            switch vpnState {
            case .disconnected:
                optimisticIsOn = true
                onConnect()
            case .connected, .connecting:
                optimisticIsOn = false
                onDisconnect()
            case .disconnecting:
                break
            }
        }
        // Clear optimistic as soon as the OS confirms any state change
        .onChange(of: vpnState) { _ in
            optimisticIsOn = nil
        }
        // Drive the pulse loop with a cancellable async task keyed to transitioning state
        .task(id: isTransitioning) {
            guard isTransitioning else {
                withAnimation(.easeInOut(duration: 0.25)) { pulseOpacity = 1.0 }
                return
            }
            while !Task.isCancelled {
                withAnimation(.easeInOut(duration: 0.85)) { pulseOpacity = 0.45 }
                try? await Task.sleep(nanoseconds: 850_000_000)
                guard !Task.isCancelled else { break }
                withAnimation(.easeInOut(duration: 0.85)) { pulseOpacity = 1.0 }
                try? await Task.sleep(nanoseconds: 850_000_000)
            }
        }
    }
}

#endif
