//
//  MainView.swift
//  NetBirdiOS
//
//  Created by Pascal Fischer on 01.08.23.
//

import SwiftUI
import Lottie
import NetworkExtension

// MARK: - Main Entry Point
/// The root view that switches between iOS and tvOS layouts.
struct MainView: View {
    @EnvironmentObject var viewModel: ViewModel

    var body: some View {
        #if os(tvOS)
        // tvOS uses a completely different navigation structure
        TVMainView()
        #else
        // iOS uses tab bar navigation
        iOSMainView()
        #endif
    }
}

#if os(iOS)

enum MainAlertType: String, Identifiable {
    case changeServer
    case serverChanged
    case preSharedKeyChanged
    case authenticationRequired

    var id: String { rawValue }
}

struct iOSMainView: View {
    @EnvironmentObject var viewModel: ViewModel
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var selectedTab = 0
    @State private var activeAlert: MainAlertType?

    init() {
        let navAppearance = UINavigationBarAppearance()
        navAppearance.configureWithOpaqueBackground()
        navAppearance.backgroundColor = UIColor(named: "BgNavigationBar")
        navAppearance.titleTextAttributes = [.foregroundColor: UIColor(named: "TextPrimary") ?? .white]
        navAppearance.largeTitleTextAttributes = [.foregroundColor: UIColor(named: "TextPrimary") ?? .white]
        UINavigationBar.appearance().standardAppearance = navAppearance
        UINavigationBar.appearance().compactAppearance = navAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navAppearance

        let tabAppearance = UITabBarAppearance()
        tabAppearance.configureWithOpaqueBackground()
        tabAppearance.backgroundColor = UIColor(named: "BgNavigationBar")
        UITabBar.appearance().standardAppearance = tabAppearance
        if #available(iOS 15.0, *) {
            UITabBar.appearance().scrollEdgeAppearance = tabAppearance
        }
    }

    var body: some View {
        ZStack {
            if !hasCompletedOnboarding {
                FirstLaunchView(
                    hasCompletedOnboarding: $hasCompletedOnboarding,
                    onChangeServer: {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            activeAlert = .changeServer
                        }
                    }
                )
            } else {
                mainContent
            }
        }
        .alert(item: $activeAlert) { alertType in
            switch alertType {
            case .changeServer:
                return Alert(
                    title: Text("Change server"),
                    message: Text("Changing server will erase the local config and disconnect this device from the current NetBird account."),
                    primaryButton: .destructive(Text("Confirm")) {
                        viewModel.handleServerChanged()
                        viewModel.navigateToServerView = true
                    },
                    secondaryButton: .cancel()
                )
            case .serverChanged:
                return Alert(
                    title: Text("Server was changed"),
                    message: Text("Click on the connect button to continue."),
                    dismissButton: .default(Text("OK"))
                )
            case .preSharedKeyChanged:
                return Alert(
                    title: Text("Preshared key was set"),
                    message: Text("Click on the connect button to continue."),
                    dismissButton: .default(Text("OK"))
                )
            case .authenticationRequired:
                return Alert(
                    title: Text("Authentication required"),
                    message: Text("The server requires a new authentication."),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
    }

    private var mainContent: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                NavigationView {
                    iOSConnectionView()
                }
                .navigationViewStyle(StackNavigationViewStyle())
                .tabItem {
                    Label("Connection", systemImage: "network")
                }
                .tag(0)

                NavigationView {
                    iOSPeersView()
                }
                .navigationViewStyle(StackNavigationViewStyle())
                .tabItem {
                    Label("Peers", systemImage: "person.3.fill")
                }
                .tag(1)

                NavigationView {
                    iOSNetworksView()
                }
                .navigationViewStyle(StackNavigationViewStyle())
                .tabItem {
                    Label("Resources", systemImage: "globe")
                }
                .tag(2)

                NavigationView {
                    iOSSettingsView()
                }
                .navigationViewStyle(StackNavigationViewStyle())
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .tag(3)
            }
            .onChange(of: viewModel.navigateToServerView) { newValue in
                if newValue {
                    selectedTab = 0
                }
            }
            .onChange(of: viewModel.showChangeServerAlert) { show in
                if show { activeAlert = .changeServer; viewModel.showChangeServerAlert = false }
            }
            .onChange(of: viewModel.showServerChangedInfo) { show in
                if show { activeAlert = .serverChanged; viewModel.showServerChangedInfo = false }
            }
            .onChange(of: viewModel.showPreSharedKeyChangedInfo) { show in
                if show { activeAlert = .preSharedKeyChanged; viewModel.showPreSharedKeyChangedInfo = false }
            }
            .onChange(of: viewModel.showAuthenticationRequired) { show in
                if show { activeAlert = .authenticationRequired; viewModel.showAuthenticationRequired = false }
            }

            // Toast alerts
            VStack {
                Spacer()
                if viewModel.showFqdnCopiedAlert {
                    HStack {
                        Image("logo-onboarding")
                            .resizable()
                            .frame(width: 20, height: 15)
                        Text("Domain name copied!")
                            .foregroundColor(.white)
                            .font(.headline)
                    }
                    .padding(5)
                    .background(Color.black.opacity(0.5))
                    .cornerRadius(8)
                    .transition(AnyTransition.opacity.combined(with: .move(edge: .top)))
                    .animation(.default, value: viewModel.showFqdnCopiedAlert)
                    .zIndex(1)
                }

                if viewModel.showIpCopiedAlert {
                    HStack {
                        Image("logo-onboarding")
                            .resizable()
                            .frame(width: 20, height: 15)
                        Text("IP address copied!")
                            .foregroundColor(.white)
                            .font(.headline)
                    }
                    .padding(5)
                    .background(Color.black.opacity(0.5))
                    .cornerRadius(8)
                    .transition(AnyTransition.opacity.combined(with: .move(edge: .top)))
                    .animation(.default, value: viewModel.showIpCopiedAlert)
                    .zIndex(1)
                }

                Spacer().frame(height: 80)
            }
        }
    }
}

struct MainView_Previews: PreviewProvider {
    static var previews: some View {
        MainView()
    }
}

#endif  // os(iOS)
