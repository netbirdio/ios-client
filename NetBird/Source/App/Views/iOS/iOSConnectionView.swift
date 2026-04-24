//
//  iOSConnectionView.swift
//  NetBird
//
//  Connection tab: VPN button, FQDN/IP display, status indicator.
//

import SwiftUI
import Lottie
import NetworkExtension

#if os(iOS)

struct iOSConnectionView: View {
    @EnvironmentObject var viewModel: ViewModel
    @State private var animationKey: UUID = UUID()
    @State private var fqdnCopied = false
    @State private var ipCopied = false

    var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            let imageName = isLandscape ? "bg-bottom-landscape" : "bg-bottom"

            ZStack {
                
                if viewModel.statusDetailsValid {
                    // Background layers
                    VStack {
                        Color("BgSecondary")
                            .frame(height: UIScreen.main.bounds.height * 4/5)
                            .ignoresSafeArea(.all)
                        Color("BgPrimary")
                            .frame(height: UIScreen.main.bounds.height * 1/5)
                            .ignoresSafeArea(.all)
                    }

                    VStack {
                        Image(imageName)
                            .resizable(resizingMode: .stretch)
                            .aspectRatio(contentMode: DeviceType.isPad ? .fill : .fit)
                            // Button overlaid directly on the image so both share the same
                            // coordinate space — mirrors Android where btn_connect is a sibling
                            // of bg_mask inside bg_mask_container.
                            // vertical_bias=0.07: button top = 7% of (imageHeight - buttonHeight)
                            // Portrait image ratio h/w = 488/360 = 1.357
                            // offset = (Screen.width*1.357 - Screen.width*0.79) * 0.07 ≈ Screen.width * 0.04
                            .overlay(alignment: .top) {
                                let btnSize = Screen.width * (isLandscape ? 0.40 : 0.79)
                                let imgH    = isLandscape
                                    ? Screen.height * 0.81               // landscape: height-constrained
                                    : Screen.width  * 1.357              // portrait: width-constrained
                                let biasOffset = max(0, (imgH - btnSize) * 0.07)

                                VStack(spacing: 0) {
                                    Color.clear.frame(height: biasOffset)

                                    Button(action: {
                                        if !viewModel.buttonLock {
                                            switch viewModel.vpnDisplayState {
                                            case .disconnected:
                                                viewModel.connect()
                                            case .connecting, .connected:
                                                viewModel.close()
                                            case .disconnecting:
                                                break
                                            }
                                        }
                                    }) {
                                        CustomLottieView(vpnState: $viewModel.vpnDisplayState)
                                            .id(animationKey)
                                            .frame(width: btnSize, height: btnSize)
                                            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                                                self.animationKey = UUID()
                                            }
                                    }

                                    Text(viewModel.extensionStateText)
                                        .foregroundColor(Color("TextSecondary"))
                                        .font(.system(size: 24, weight: .regular))
                                        .padding(.top, 24)

                                    Spacer()
                                }
                            }
                            .padding(.top, Screen.height * (DeviceType.isPad ? (isLandscape ? -0.15 : 0.36) : 0.19))
                            .padding(.leading, UIScreen.main.bounds.height * (isLandscape ? 0.04 : 0))
                            .frame(width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.height)
                            .edgesIgnoringSafeArea(.bottom)
                    }

                    // FQDN + IP
                    VStack {
                        Text(fqdnCopied ? "Copied" : viewModel.fqdn)
                            .foregroundColor(Color("TextPrimary"))
                            .font(.system(size: 20, weight: .regular))
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .opacity(fqdnCopied ? 0.7 : 1.0)
                            .animation(.easeInOut(duration: 0.2), value: fqdnCopied)
                            .padding(.horizontal, 16)
                            .padding(.top, Screen.height * (DeviceType.isPad ? 0.09 : 0.13))
                            .padding(.bottom, 5)
                            .onTapGesture {
                                guard !viewModel.fqdn.isEmpty else { return }
                                UIPasteboard.general.string = viewModel.fqdn
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                withAnimation(.smooth) {
                                    fqdnCopied = true
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                    withAnimation(.smooth) {
                                        fqdnCopied = false
                                    }
                                }
                            }

                        Text(ipCopied ? "Copied" : viewModel.ip)
                            .foregroundColor(Color("TextPrimary"))
                            .font(.system(size: 20, weight: .regular))
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .opacity(ipCopied ? 0.7 : 1.0)
                            .animation(.easeInOut(duration: 0.2), value: ipCopied)
                            .onTapGesture {
                                guard !viewModel.ip.isEmpty else { return }
                                UIPasteboard.general.string = viewModel.ip
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                withAnimation(.smooth) {
                                    ipCopied = true
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                    withAnimation(.smooth) {
                                        ipCopied = false
                                    }
                                }
                            }

                        Spacer()
                    }

                    // Network warning banner – above tab bar
                    if viewModel.vpnDisplayState == .connected && !viewModel.isInternetConnected {
                        VStack {
                            Spacer()
                            NetworkWarningBanner()
                                .padding(.bottom, geometry.safeAreaInsets.bottom + 80)
                        }
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                        .animation(.easeInOut(duration: 0.3), value: viewModel.isInternetConnected)
                    }

                    // Hidden NavigationLink for ServerView
                    NavigationLink("", destination: ServerView(), isActive: $viewModel.navigateToServerView)
                        .hidden()
                        .onChange(of: viewModel.navigateToServerView) { newValue in
                            if !newValue {
                                viewModel.startPollingDetails()
                            }
                        }

                } else {
                    // Loading placeholder
                    ZStack {
                        Color("BgPrimary")
                            .ignoresSafeArea()
                        Image("netbird-logo-menu")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 200)
                    }
                }

                // Safari login view — shown regardless of statusDetailsValid
                if viewModel.networkExtensionAdapter.showBrowser,
                   let loginURLString = viewModel.networkExtensionAdapter.loginURL,
                   let loginURL = URL(string: loginURLString)
                {
                    SafariView(isPresented: $viewModel.networkExtensionAdapter.showBrowser,
                               url: loginURL,
                               didFinish: {
                        print("Finish login")
                        viewModel.networkExtensionAdapter.startVPNConnection()
                    })
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarHidden(true)
    }
}

#endif
