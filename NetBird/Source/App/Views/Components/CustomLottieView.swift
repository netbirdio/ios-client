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
    @StateObject var viewModel: ViewModel
    
    func makeUIView(context: Context) -> LottieAnimationView {
        let animationView = LottieAnimationView()
        animationView.animation = LottieAnimation.named(colorScheme == .dark ? "button-full2-dark" :  "button-full2")
        context.coordinator.colorScheme = colorScheme
        animationView.contentMode = .scaleAspectFit
        return animationView
    }

    func updateUIView(_ uiView: LottieAnimationView, context: Context) {
        // Status change check
        if context.coordinator.extensionStatus != extensionStatus || context.coordinator.engineStatus != engineStatus
            || context.coordinator.connectPressed != connectPressed || context.coordinator.disconnectPressed != disconnectPressed {
            // Update the coordinator's state
            context.coordinator.extensionStatus = extensionStatus
            context.coordinator.engineStatus = engineStatus
            context.coordinator.connectPressed = connectPressed
            context.coordinator.disconnectPressed = disconnectPressed
            
            if context.coordinator.isPlaying {
                print("Is still playing")
                return
            }
            // Act based on the new status
            switch extensionStatus {
            case .connected:
                print("Management status chnaged to \(engineStatus)")
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
                    context.coordinator.playConnectingLoop(uiView: uiView, viewModel: viewModel)
                case .disconnected:
                    break
                case .disconnecting:
                    break
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
                    print("Connected pressed = \(String(describing: self.connectPressed?.description))")
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
                } else if self.engineStatus == .connected {
                    // Engine reconnected (e.g., after network switch) - show connected state
                    self.isPlaying = false
                    DispatchQueue.main.async {
                        viewModel.extensionStateText = "Connected"
                    }
                    uiView.currentFrame = self.connectedFrame
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
                } else if self.engineStatus == .connected {
                    // Engine reconnected (e.g., after network switch) - show connected state
                    self.isPlaying = false
                    DispatchQueue.main.async {
                        viewModel.extensionStateText = "Connected"
                    }
                    uiView.currentFrame = self.connectedFrame
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
