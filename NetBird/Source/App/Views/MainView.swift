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
struct iOSMainView: View {
    @EnvironmentObject var viewModel: ViewModel
    @State private var selectedTab = 0

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
                    Label("Networks", systemImage: "globe")
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

            // Alert overlays (rendered above all tabs)
            if viewModel.showChangeServerAlert {
                Color.black.opacity(0.4)
                    .edgesIgnoringSafeArea(.all)
                    .onTapGesture {
                        viewModel.showChangeServerAlert = false
                    }
                ChangeServerAlert(viewModel: viewModel, isPresented: $viewModel.showChangeServerAlert)
                    .frame(maxWidth: UIScreen.main.bounds.width * 0.9)
            }

            if viewModel.showServerChangedInfo {
                Color.black.opacity(0.4)
                    .edgesIgnoringSafeArea(.all)
                    .onTapGesture {
                        viewModel.showServerChangedInfo = false
                    }
                ChangeServerInfoAlert(viewModel: viewModel, isPresented: $viewModel.showServerChangedInfo)
                    .frame(maxWidth: UIScreen.main.bounds.width * 0.9)
            }

            if viewModel.showPreSharedKeyChangedInfo {
                Color.black.opacity(0.4)
                    .edgesIgnoringSafeArea(.all)
                    .onTapGesture {
                        viewModel.showPreSharedKeyChangedInfo = false
                    }
                ChangePreSharedKeyAlert(viewModel: viewModel, isPresented: $viewModel.showPreSharedKeyChangedInfo)
                    .frame(maxWidth: UIScreen.main.bounds.width * 0.9)
            }

            if viewModel.showAuthenticationRequired && false {
                Color.black.opacity(0.4)
                    .edgesIgnoringSafeArea(.all)
                    .onTapGesture {
                        viewModel.buttonLock = true
                        viewModel.showAuthenticationRequired = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            viewModel.buttonLock = false
                        }
                    }
                AuthenticationAlert(viewModel: viewModel, isPresented: $viewModel.showAuthenticationRequired)
                    .frame(maxWidth: UIScreen.main.bounds.width * 0.9)
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

// MARK: - Alert Views

struct ChangeServerAlert: View {
    @StateObject var viewModel: ViewModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 20) {
            Image("exclamation-circle")
                .padding(.top, 20)
            Text("Change server")
                .font(.title)
                .foregroundColor(Color("TextAlert"))
            Text("Changing server will erase the local config and disconnect this device from the current NetBird account.")
                .foregroundColor(Color("TextAlert"))
                .multilineTextAlignment(.center)
            SolidButton(text: "Confirm") {
                viewModel.handleServerChanged()
                isPresented = false
                viewModel.navigateToServerView = true
            }
            .padding(.top, 20)

            Button {
                isPresented.toggle()
            } label: {
                Text("Cancel")
                    .font(.headline)
                    .foregroundColor(Color.accentColor)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(red: 0, green: 0, blue: 0, opacity: 0))
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(Color.accentColor, lineWidth: 1)
                            )
                    )
            }
        }
        .padding()
        .background(Color("BgSideDrawer"))
        .cornerRadius(15)
        .shadow(radius: 10)
    }
}

struct ChangeServerInfoAlert: View {
    @StateObject var viewModel: ViewModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 20) {
            Image("check-circle")
                .padding(.top, 20)
            Text("Server was changed")
                .font(.title)
                .foregroundColor(Color("TextAlert"))
            Text("Click on the connect button to continue.")
                .multilineTextAlignment(.center)
                .foregroundColor(Color("TextAlert"))
            SolidButton(text: "Ok") {
                viewModel.showServerChangedInfo = false
            }
            .padding(.top, 20)
        }
        .padding()
        .background(Color("BgSideDrawer"))
        .cornerRadius(15)
        .shadow(radius: 10)
    }
}

struct ChangePreSharedKeyAlert: View {
    @StateObject var viewModel: ViewModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 20) {
            Image("check-circle")
                .padding(.top, 20)
            Text("Preshared key was set")
                .font(.title)
                .foregroundColor(Color("TextAlert"))
            Text("Click on the connect button to continue.")
                .multilineTextAlignment(.center)
                .foregroundColor(Color("TextAlert"))
            SolidButton(text: "Ok") {
                viewModel.showPreSharedKeyChangedInfo = false
            }
            .padding(.top, 20)
        }
        .padding()
        .background(Color("BgSideDrawer"))
        .cornerRadius(15)
        .shadow(radius: 10)
    }
}

struct AuthenticationAlert: View {
    @StateObject var viewModel: ViewModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 20) {
            Image("exclamation-circle")
                .padding(.top, 20)
            Text("Authentication required")
                .foregroundColor(Color("TextAlert"))
                .font(.title)
            Text("The server requires a new authentication.")
                .foregroundColor(Color("TextAlert"))
                .multilineTextAlignment(.center)
            SolidButton(text: "Ok") {
                viewModel.buttonLock = true
                viewModel.showAuthenticationRequired = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    viewModel.buttonLock = false
                }
            }
            .padding(.top, 20)
        }
        .padding()
        .background(Color("BgSideDrawer"))
        .cornerRadius(15)
        .shadow(radius: 10)
    }
}

struct MainView_Previews: PreviewProvider {
    static var previews: some View {
        MainView()
    }
}

#endif  // os(iOS)
