import Foundation
import SwiftUI
import Lottie
import NetworkExtension

struct CustomLottieView: UIViewRepresentable {
    @Environment(\.colorScheme) var colorScheme
    @Binding var vpnState: VPNDisplayState

    func makeUIView(context: Context) -> LottieAnimationView {
        let animationView = LottieAnimationView()
        animationView.animation = LottieAnimation.named(colorScheme == .dark ? "button-full2-dark" : "button-full2")
        animationView.contentMode = .scaleAspectFit

        // Set initial frame based on current state
        if vpnState == .connected {
            animationView.currentFrame = context.coordinator.connectedFrame
        } else {
            animationView.currentFrame = context.coordinator.disconnectedFrame
        }

        context.coordinator.currentState = vpnState
        return animationView
    }

    func updateUIView(_ uiView: LottieAnimationView, context: Context) {
        let previousState = context.coordinator.currentState
        let newState = vpnState

        guard previousState != newState else { return }
        context.coordinator.currentState = newState

        // Stop any running animation before starting a new one
        if context.coordinator.isPlaying {
            uiView.stop()
            context.coordinator.isPlaying = false
        }

        switch (previousState, newState) {
        // Normal flow: disconnected -> connecting
        case (.disconnected, .connecting):
            context.coordinator.playConnectingFadeIn(uiView: uiView)

        // Normal flow: connecting -> connected
        case (.connecting, .connected):
            context.coordinator.playConnectingFadeOut(uiView: uiView)

        // Normal flow: connected -> disconnecting
        case (.connected, .disconnecting):
            context.coordinator.playDisconnectingFadeIn(uiView: uiView)

        // Normal flow: disconnecting -> disconnected
        case (.disconnecting, .disconnected):
            context.coordinator.playDisconnectingFadeOut(uiView: uiView)

        // Edge case: connecting -> disconnecting (user cancelled)
        case (.connecting, .disconnecting):
            context.coordinator.playDisconnectingFadeIn(uiView: uiView)

        // Edge case: connecting -> disconnected (failed or cancelled)
        case (.connecting, .disconnected):
            context.coordinator.playDisconnectingFadeOut(uiView: uiView)

        // Edge case: disconnecting -> connecting (reconnect)
        case (.disconnecting, .connecting):
            context.coordinator.playConnectingFadeIn(uiView: uiView)

        // Direct jump to connected (e.g. app foreground)
        case (_, .connected):
            uiView.currentFrame = context.coordinator.connectedFrame

        // Direct jump to disconnected (e.g. network unavailable)
        case (_, .disconnected):
            uiView.currentFrame = context.coordinator.disconnectedFrame

        default:
            break
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(initialState: vpnState)
    }

    class Coordinator: NSObject {
        var isPlaying = false
        var currentState: VPNDisplayState

        init(initialState: VPNDisplayState) {
            self.currentState = initialState
            super.init()
        }

        let connectedFrame: CGFloat = 142
        let disconnectedFrame: CGFloat = 339
        let connectingFadeIn: (startFrame: CGFloat, endFrame: CGFloat) = (0, 78)
        let connectingLoopRange: (startFrame: CGFloat, endFrame: CGFloat) = (78, 120)
        let connectingFadeOut: (startFrame: CGFloat, endFrame: CGFloat) = (121, 142)
        let disconnectingFadeIn: (startFrame: CGFloat, endFrame: CGFloat) = (152, 214)
        let disconnectingLoopRange: (startFrame: CGFloat, endFrame: CGFloat) = (215, 258)
        let disconnectingFadeOut: (startFrame: CGFloat, endFrame: CGFloat) = (259, 339)

        func playConnectingFadeIn(uiView: LottieAnimationView) {
            self.isPlaying = true
            uiView.play(fromFrame: connectingFadeIn.startFrame, toFrame: connectingFadeIn.endFrame, loopMode: .playOnce) { [weak self] _ in
                guard let self = self else { return }
                if self.currentState == .connected {
                    self.playConnectingFadeOut(uiView: uiView)
                } else if self.currentState == .connecting {
                    self.playConnectingLoop(uiView: uiView)
                } else {
                    self.isPlaying = false
                }
            }
        }

        func playConnectingLoop(uiView: LottieAnimationView) {
            self.isPlaying = true
            uiView.play(fromFrame: connectingLoopRange.startFrame, toFrame: connectingLoopRange.endFrame, loopMode: .playOnce) { [weak self] _ in
                guard let self = self else { return }
                if self.currentState == .connected {
                    self.playConnectingFadeOut(uiView: uiView)
                } else if self.currentState == .connecting {
                    self.playConnectingLoop(uiView: uiView)
                } else {
                    self.isPlaying = false
                }
            }
        }

        func playConnectingFadeOut(uiView: LottieAnimationView) {
            self.isPlaying = true
            uiView.play(fromFrame: connectingFadeOut.startFrame, toFrame: connectingFadeOut.endFrame, loopMode: .playOnce) { [weak self] _ in
                self?.isPlaying = false
            }
        }

        func playDisconnectingFadeIn(uiView: LottieAnimationView) {
            self.isPlaying = true
            uiView.play(fromFrame: disconnectingFadeIn.startFrame, toFrame: disconnectingFadeIn.endFrame, loopMode: .playOnce) { [weak self] _ in
                guard let self = self else { return }
                if self.currentState == .disconnected {
                    self.playDisconnectingFadeOut(uiView: uiView)
                } else if self.currentState == .disconnecting {
                    self.playDisconnectingLoop(uiView: uiView)
                } else {
                    self.isPlaying = false
                }
            }
        }

        func playDisconnectingLoop(uiView: LottieAnimationView) {
            self.isPlaying = true
            uiView.play(fromFrame: disconnectingLoopRange.startFrame, toFrame: disconnectingLoopRange.endFrame, loopMode: .playOnce) { [weak self] _ in
                guard let self = self else { return }
                if self.currentState == .disconnected {
                    self.playDisconnectingFadeOut(uiView: uiView)
                } else if self.currentState == .disconnecting {
                    self.playDisconnectingLoop(uiView: uiView)
                } else {
                    self.isPlaying = false
                }
            }
        }

        func playDisconnectingFadeOut(uiView: LottieAnimationView) {
            self.isPlaying = true
            uiView.play(fromFrame: disconnectingFadeOut.startFrame, toFrame: disconnectingFadeOut.endFrame, loopMode: .playOnce) { [weak self] _ in
                self?.isPlaying = false
            }
        }
    }
}
