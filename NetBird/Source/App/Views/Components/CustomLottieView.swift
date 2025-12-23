import Foundation
import SwiftUI
import Lottie
import NetworkExtension

struct CustomLottieView: UIViewRepresentable {
    @Environment(\.colorScheme) var colorScheme
    @Binding var extensionStatus: NEVPNStatus
    @Binding var engineStatus: ClientState
    @Binding var connectPressed: Bool
    @Binding var disconnectPressed: Bool
    @Binding var networkUnavailable: Bool
    @StateObject var viewModel: ViewModel

    func makeUIView(context: Context) -> LottieAnimationView {
        let animationView = LottieAnimationView()
        animationView.animation = LottieAnimation.named(colorScheme == .dark ? "button-full2-dark" :  "button-full2")
        context.coordinator.colorScheme = colorScheme
        animationView.contentMode = .scaleAspectFit
        return animationView
    }

    func updateUIView(_ uiView: LottieAnimationView, context: Context) {
        // Check for network unavailable state change (airplane mode)
        if context.coordinator.networkUnavailable != networkUnavailable {
            context.coordinator.networkUnavailable = networkUnavailable

            if networkUnavailable && !context.coordinator.isPlaying {
                // Network just became unavailable - trigger disconnecting animation
                DispatchQueue.main.async {
                    context.coordinator.playDisconnectingFadeIn(uiView: uiView, viewModel: viewModel)
                }
                return
            }
        }

        // Status change check
        if context.coordinator.extensionStatus != extensionStatus || context.coordinator.engineStatus != engineStatus
            || context.coordinator.connectPressed != connectPressed || context.coordinator.disconnectPressed != disconnectPressed {
            // Update the coordinator's state
            context.coordinator.extensionStatus = extensionStatus
            context.coordinator.engineStatus = engineStatus
            context.coordinator.connectPressed = connectPressed
            context.coordinator.disconnectPressed = disconnectPressed

            // Force reset to disconnected state when all flags indicate disconnected
            // This handles cases like server change where we need to immediately reset
            let shouldForceReset = extensionStatus == .disconnected
                && !connectPressed
                && !disconnectPressed
                && engineStatus == .disconnected

            if shouldForceReset {
                context.coordinator.isPlaying = false
                uiView.stop()
                uiView.currentFrame = context.coordinator.disconnectedFrame
                return
            }

            if context.coordinator.isPlaying {
                return
            }
            // Act based on the new status
            switch extensionStatus {
            case .connected:
                if disconnectPressed {
                    DispatchQueue.main.async {
                        context.coordinator.playDisconnectingFadeIn(uiView: uiView, viewModel: viewModel)
                    }
                }
                switch engineStatus {
                case .connected:
                    DispatchQueue.main.async {
                        viewModel.extensionStateText = "Connected"
                        viewModel.routeViewModel.getRoutes()
                    }
                    uiView.currentFrame = context.coordinator.connectedFrame
                case .connecting:
                    // Play connecting animation - the loop has proper exit conditions
                    // for both user-initiated and automatic reconnections
                    context.coordinator.playConnectingLoop(uiView: uiView, viewModel: viewModel)
                case .disconnected:
                    // Engine disconnected but tunnel still up - show disconnected state
                    DispatchQueue.main.async {
                        viewModel.extensionStateText = "Disconnected"
                    }
                    uiView.currentFrame = context.coordinator.disconnectedFrame
                case .disconnecting:
                    DispatchQueue.main.async {
                        context.coordinator.playDisconnectingFadeIn(uiView: uiView, viewModel: viewModel)
                    }
                }
            case .disconnected:
                if connectPressed {
                    DispatchQueue.main.async {
                        context.coordinator.playConnectingFadeIn(uiView: uiView, viewModel: viewModel)
                    }
                }
                DispatchQueue.main.async {
                    viewModel.extensionStateText = "Disconnected"
                }
                uiView.currentFrame = context.coordinator.disconnectedFrame
            case .connecting:
                DispatchQueue.main.async {
                    context.coordinator.playConnectingFadeIn(uiView: uiView, viewModel: viewModel)
                }
            case .disconnecting:
                DispatchQueue.main.async {
                    context.coordinator.playDisconnectingFadeIn(uiView: uiView, viewModel: viewModel)
                }
            default:
                break
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject {
        var isPlaying = false
        var extensionStatus: NEVPNStatus?
        var engineStatus: ClientState?
        var connectPressed: Bool?
        var disconnectPressed: Bool?
        var networkUnavailable: Bool = false
        var colorScheme: ColorScheme?
        
        let connectedFrame: CGFloat = 142
        let disconnectedFrame: CGFloat = 339
        let connectingFadeIn: (startFrame: CGFloat, endFrame: CGFloat) = (0, 78)
        let connectingLoopRange: (startFrame: CGFloat, endFrame: CGFloat) = (78, 120)
        let connectingFadeOut: (startFrame: CGFloat, endFrame: CGFloat) = (121, 142)
        let disconnectingLoopFadeIn: (startFrame: CGFloat, endFrame: CGFloat) = (152, 214)
        let disconnectingLoopRange: (startFrame: CGFloat, endFrame: CGFloat) = (215, 258)
        let disconnectingFadeOut: (startFrame: CGFloat, endFrame: CGFloat) = (259, 339)

        
        func playConnectingFadeIn(uiView: LottieAnimationView, viewModel: ViewModel) {
            DispatchQueue.main.async {
                viewModel.extensionStateText = "Connecting..."
            }
            self.isPlaying = true
            uiView.play(fromFrame: connectingFadeIn.startFrame, toFrame: connectingFadeIn.endFrame, loopMode: .playOnce) { [weak self] finished in
                guard let self = self else { return }
                if self.engineStatus == .connected {
                    self.playFadeOut(uiView: uiView, startFrame: self.connectingFadeOut.startFrame, endFrame: self.connectingFadeOut.endFrame, viewModel: viewModel, extensionStateText: "Connected")
                } else {
                    // Loop the connecting animation only if the status is still connecting
                    playConnectingLoop(uiView: uiView, viewModel: viewModel)
                }
            }
        }
        
        func playConnectingLoop(uiView: LottieAnimationView, viewModel: ViewModel) {
            self.isPlaying = true
            DispatchQueue.main.async {
                viewModel.extensionStateText = "Connecting..."
            }
            uiView.play(fromFrame: self.connectingLoopRange.startFrame, toFrame: self.connectingLoopRange.endFrame, loopMode: .playOnce) {[weak self] finished in
                guard let self = self else { return }
                if self.engineStatus == .connected {
                    self.playFadeOut(uiView: uiView, startFrame: self.connectingFadeOut.startFrame, endFrame: self.connectingFadeOut.endFrame, viewModel: viewModel, extensionStateText: "Connected")
                } else if (self.engineStatus == .disconnecting || self.extensionStatus == .disconnecting || self.engineStatus == .disconnected || self.extensionStatus == .disconnected) && !(self.connectPressed ?? false) {
                    self.playDisconnectingLoop(uiView: uiView, viewModel: viewModel)
                } else if !(self.connectPressed ?? false) && self.engineStatus == .connecting {
                    // Automatic reconnection (not user-initiated) stuck in connecting state
                    // Exit to disconnected state after one loop to avoid infinite animation
                    self.playDisconnectingLoop(uiView: uiView, viewModel: viewModel)
                } else {
                    playConnectingLoop(uiView: uiView, viewModel: viewModel)
                }
            }
        }
        
        func playDisconnectingFadeIn(uiView: LottieAnimationView, viewModel: ViewModel) {
            self.isPlaying = true
            DispatchQueue.main.async {
                viewModel.extensionStateText = "Disconnecting..."
            }
            uiView.play(fromFrame: disconnectingLoopFadeIn.startFrame, toFrame: disconnectingLoopFadeIn.endFrame, loopMode: .playOnce) { [weak self] finished in
                guard let self = self else { return }
                if self.extensionStatus == .disconnected {
                    self.playFadeOut(uiView: uiView, startFrame: self.disconnectingFadeOut.startFrame, endFrame: self.disconnectingFadeOut.endFrame, viewModel: viewModel, extensionStateText: "Disconnected")
                } else {
                    DispatchQueue.main.async {
                        viewModel.connectPressed = false
                    }
                    playDisconnectingLoop(uiView: uiView, viewModel: viewModel)
                }
            }
        }
        
        func playDisconnectingLoop(uiView: LottieAnimationView, viewModel: ViewModel) {
            self.isPlaying = true
            DispatchQueue.main.async {
                viewModel.extensionStateText = "Disconnecting..."
            }
            uiView.play(fromFrame: self.disconnectingLoopRange.startFrame, toFrame: self.disconnectingLoopRange.endFrame, loopMode: .playOnce) { [weak self] finished in
                guard let self = self else { return }
                if self.extensionStatus == .disconnected {
                    self.playFadeOut(uiView: uiView, startFrame: self.disconnectingFadeOut.startFrame, endFrame: self.disconnectingFadeOut.endFrame, viewModel: viewModel, extensionStateText: "Disconnected")
                } else if self.engineStatus == .connected && self.extensionStatus == .connected && !self.networkUnavailable {
                    // Engine recovered to connected during internal restart (e.g., network switch)
                    // Extension never disconnected, so skip fade out and go directly to connected state
                    // Only if network is available (not airplane mode)
                    DispatchQueue.main.async {
                        self.isPlaying = false
                        uiView.currentFrame = self.connectedFrame
                        viewModel.extensionStateText = "Connected"
                        viewModel.connectPressed = false
                        viewModel.disconnectPressed = false
                        viewModel.routeViewModel.getRoutes()
                    }
                } else if self.networkUnavailable || ((self.engineStatus == .disconnected || self.engineStatus == .connecting) && self.extensionStatus == .connected) {
                    // Network unavailable (airplane mode) or engine disconnected/stuck connecting
                    // Show disconnected state immediately
                    DispatchQueue.main.async {
                        self.isPlaying = false
                        uiView.currentFrame = self.disconnectedFrame
                        viewModel.extensionStateText = "Disconnected"
                        viewModel.connectPressed = false
                        viewModel.disconnectPressed = false
                    }
                } else {
                    playDisconnectingLoop(uiView: uiView, viewModel: viewModel)
                }
            }
        }

        func playFadeOut(uiView: LottieAnimationView, startFrame: CGFloat, endFrame: CGFloat, viewModel: ViewModel, extensionStateText: String) {
            self.isPlaying = true
            uiView.play(fromFrame: startFrame, toFrame: endFrame, loopMode: .playOnce) { [weak self] finished in
                DispatchQueue.main.async {
                    self?.isPlaying = false
                    viewModel.extensionStateText = extensionStateText
                    viewModel.connectPressed = false
                    viewModel.disconnectPressed = false
                }
            }
        }
    }
}
