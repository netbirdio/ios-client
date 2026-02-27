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
                            .aspectRatio(contentMode: .fit)
                            .padding(.top, Screen.height * (DeviceType.isPad ? (isLandscape ? -0.15 : 0.36) : 0.19))
                            .padding(.leading, UIScreen.main.bounds.height * (isLandscape ? 0.04 : 0))
                            .frame(width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.height)
                            .edgesIgnoringSafeArea(.bottom)
                    }

                    // FQDN + IP + internet status
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

                    // VPN button + status text
                    VStack {
                        Spacer()
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
                            CustomLottieView(vpnState: $viewModel.vpnDisplayState, viewModel: viewModel)
                                .id(animationKey)
                                .frame(width: UIScreen.main.bounds.width * (isLandscape ? 0.40 : 0.79), height: UIScreen.main.bounds.width * (isLandscape ? 0.40 : 0.79))
                                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                                    self.animationKey = UUID()
                                }
                        }
                        .padding(.top, -UIScreen.main.bounds.height / 27)
                        .padding(.bottom)

                        Text(viewModel.extensionStateText)
                            .foregroundColor(Color("TextSecondary"))
                            .font(.system(size: 24, weight: .regular))

                        Spacer()
                    }
                    .padding()

                    // Hidden NavigationLink for ServerView
                    NavigationLink("", destination: ServerView(), isActive: $viewModel.navigateToServerView)
                        .hidden()
                        .onChange(of: viewModel.navigateToServerView) { newValue in
                            if !newValue {
                                viewModel.startPollingDetails()
                            }
                        }

                    // Safari login view
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
                    // Internet status – top-left corner
                    if !viewModel.networkExtensionAdapter.showBrowser {
                        InternetStatusView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .padding(.top, 16)
                            .padding(.leading, 16)
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
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarHidden(true)
    }
}

#endif
