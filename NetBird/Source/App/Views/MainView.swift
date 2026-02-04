//
//  MainView.swift
//  NetBirdiOS
//
//  Created by Pascal Fischer on 01.08.23.
//

import SwiftUI
import Lottie
import NetworkExtension
import Combine

// MARK: - Main Entry Point
/// The root view that switches between iOS and tvOS layouts.
struct MainView: View {
    @EnvironmentObject var viewModel: ViewModel
    
    var body: some View {
        #if os(tvOS)
        // tvOS uses a completely different navigation structure
        TVMainView()
        #else
        // iOS uses the original MainView implementation
        iOSMainView()
        #endif
    }
}

#if os(iOS)
struct iOSMainView: View {
    @EnvironmentObject var viewModel: ViewModel
    @State private var isSheetshown = true
    @State private var animationKey: UUID = UUID()
    
    @State private var isPressed = false
    @State private var showRouteSelection = false
    @State private var allSelected = false
    @State private var fqdnCopied = false
    @State private var ipCopied = false
    
    init() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(named: "BgNavigationBar")

        // Set the appearance for when the navigation bar is displayed regularly
        UINavigationBar.appearance().standardAppearance = appearance

        // Set the appearance for when the navigation bar has a collapsed state
        UINavigationBar.appearance().compactAppearance = appearance // Optional

        // Set the appearance for when the navigation bar is displayed in a scroll edge context
        UINavigationBar.appearance().scrollEdgeAppearance = appearance // For iOS 15 and later
    }
    
    var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            let imageName = isLandscape ? "bg-bottom-landscape" : "bg-bottom"
            NavigationView {
                ZStack {
                    if viewModel.statusDetailsValid {
                        VStack {
                            Color("BgSecondary")
                                .frame(height: UIScreen.main.bounds.height * 3/5)
                                .ignoresSafeArea(.all)
                            Color("BgPrimary")
                                .frame(height: UIScreen.main.bounds.height * 2/5)
                                .ignoresSafeArea(.all)
                        }
                        VStack {
                            
                            Image(imageName)
                                .resizable(resizingMode: .stretch)
                                .aspectRatio(contentMode: .fit)
                            //                                .padding(.top, Screen.height * (DeviceType.isPad ? 0.34 : 0.13))
                                .padding(.top, Screen.height * (DeviceType.isPad ? (isLandscape ? -0.15 : 0.36) : 0.19))
                                .padding(.leading, UIScreen.main.bounds.height * (isLandscape ? 0.04 : 0))
                                .frame(width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.height)
                                .edgesIgnoringSafeArea(.bottom)
                            
                        }
                        VStack {
                            Text(fqdnCopied ? "Copied" : viewModel.fqdn)
                                .foregroundColor(Color("TextSecondary"))
                                .font(.system(size: 20, weight: .regular))
                                .opacity(fqdnCopied ? 0.7 : 1.0)
                                .animation(.easeInOut(duration: 0.2), value: fqdnCopied)
                                .padding(.top, Screen.height * (DeviceType.isPad ? 0.09 : 0.13))
                                .padding(.bottom, 5)
                                .onTapGesture {
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
                                .foregroundColor(Color("TextSecondary"))
                                .font(.system(size: 20, weight: .regular))
                                .opacity(ipCopied ? 0.7 : 1.0)
                                .animation(.easeInOut(duration: 0.2), value: ipCopied)
                                .onTapGesture {
                                    UIPasteboard.general.string = viewModel.ip
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    withAnimation {
                                        ipCopied = true
                                    }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                        withAnimation {
                                            ipCopied = false
                                        }
                                    }
                                }
                            Spacer()
                        }
                        VStack() {
                            HStack {
                                Button {
                                    viewModel.presentSideDrawer = true
                                } label: {
                                    Image("hamburgerMenu")
                                        .resizable()
                                        .frame(width: 35, height: 35)
                                        .padding(.top, UIScreen.main.bounds.height * 0.03)
                                }
                                Spacer()
                            }
                            Spacer()
                            Button(action: {
                                if !viewModel.buttonLock {
                                    if viewModel.extensionState == .disconnected {
                                        viewModel.connect()
                                    } else if viewModel.extensionState == .connecting || viewModel.managementStatus == .connecting || viewModel.extensionState == .connected {
                                        print("Trying to stop extension")
                                        viewModel.close()
                                    }
                                }
                            }) {
                                CustomLottieView(extensionStatus: $viewModel.extensionState, engineStatus: $viewModel.managementStatus, connectPressed: $viewModel.connectPressed, disconnectPressed: $viewModel.disconnectPressed, networkUnavailable: $viewModel.networkUnavailable, viewModel: viewModel)
                                    .id(animationKey)
                                    .frame(width: UIScreen.main.bounds.width * (isLandscape ? 0.40 : 0.79), height: UIScreen.main.bounds.width * (isLandscape ? 0.40 : 0.79))
                                    .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                                        withAnimation {
                                            self.animationKey = UUID()
                                        }
                                    }
                            }
                            .padding(.top, -UIScreen.main.bounds.height / 27)
                            .padding(.bottom)
                            Text(viewModel.extensionStateText)
                                .foregroundColor(Color("TextSecondary"))
                                .font(.system(size: 24, weight: .regular))
                            //                        ProfileSwitcherView(vm: viewModel)
                            //                            .padding(.top, 3)
                            Spacer()
                        }
                        .padding()
                        SheetView()
                        SideDrawer(viewModel: viewModel, isShowing: $viewModel.presentSideDrawer)
                        NavigationLink("", destination: ServerView(), isActive: $viewModel.navigateToServerView)
                            .hidden()
                            .onChange(of: viewModel.navigateToServerView) { newValue in
                                  if !newValue {
                                      viewModel.startPollingDetails()
                                  }
                            }
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
                        ZStack {
                            VStack {
                                Spacer()
                                if viewModel.showFqdnCopiedAlert {
                                    VStack {
                                        Spacer()
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
                                        Spacer().frame(height: 40)
                                    }
                                }
                                
                                if viewModel.showIpCopiedAlert {
                                    VStack {
                                        Spacer()
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
                                        Spacer().frame(height: 40)
                                    }
                                }
                            }
                            .padding(.bottom, 40)
                        }
                    } else {
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
                .navigationBarTitleDisplayMode(.inline)
                .navigationBarHidden(true)
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}

class KeyboardObserver: ObservableObject {
    @Published var keyboardHeight: CGFloat = 0
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)
            .compactMap { $0.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect }
            .map { $0.height }
            .assign(to: \.keyboardHeight, on: self)
            .store(in: &cancellables)
        
        NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)
            .map { _ in CGFloat(0) }
            .assign(to: \.keyboardHeight, on: self)
            .store(in: &cancellables)
    }
}

struct SheetView: View {
    @EnvironmentObject var viewModel: ViewModel
    @StateObject private var keyboardObserver = KeyboardObserver()
    
    @GestureState private var translation: CGFloat = 0
    @State private var showDropdown: Bool = false
    @State var selectedTab = 1
    @State private var isAnimating = false
    
    let isIpad = UIDevice.current.userInterfaceIdiom == .pad
    
    var body: some View {
        ZStack {
            ZStack {
                VStack {
                    Button {
                        withAnimation(.linear(duration: 0.2)) {
                            viewModel.isSheetExpanded.toggle()
                        }
                    } label: {
                        Handlebar()
                            .padding(.top, 5)
                    }
                    
                    HStack {
                        if selectedTab == 1 {
                            Text((viewModel.extensionStateText != "Connected" ? "0" : viewModel.peerViewModel.peerInfo.filter { $0.connStatus == "Connected" }.count.description)
                                + " of "
                                + (viewModel.extensionStateText != "Connected" ? "0" : viewModel.peerViewModel.peerInfo.count.description))
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(Color("TextSecondary"))
                            Text("Peers connected")
                                .font(.system(size: 18, weight: .regular))
                                .foregroundColor(Color("TextSecondary"))
                        } else {
                            Text((viewModel.extensionStateText != "Connected" ? "0" : viewModel.routeViewModel.routeInfo.filter { $0.selected }.count.description)
                                + " of "
                                + (viewModel.extensionStateText != "Connected" ? "0" : viewModel.routeViewModel.routeInfo.count.description))
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(Color("TextSecondary"))
                            Text("Resources connected")
                                .font(.system(size: 18, weight: .regular))
                                .foregroundColor(Color("TextSecondary"))
                        }
                    }
                    .padding(.top, UIScreen.main.bounds.height * (isIpad ? 0.03 : 0.006))
                    .padding(.bottom, viewModel.isSheetExpanded ? 5 : 30)
                    
                    TabView(selection: $selectedTab) {
                        PeerTabView()
                            .tag(1)
                        
                        RouteTabView()
                            .tag(2)
                    }
                    .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
                    
                    HStack {
                        TabBarButton(label: "Peers", image: "peers", selectedTab: $selectedTab, index: 1)
                        TabBarButton(label: "Networks", image: "networks", selectedTab: $selectedTab, index: 2)
                    }
                    .padding(.bottom, 20)
                    .background(Color("BgNavigationBar"))
                    .frame(height: 50)
                }
                .padding(.bottom, 100)
                .ignoresSafeArea(.keyboard, edges: .bottom)
                
                if viewModel.isSheetExpanded {
                    VStack {
                        HStack {
                            if selectedTab == 2 {
                                Button {
                                    isAnimating = true
                                    viewModel.routeViewModel.getRoutes()
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) {
                                        self.isAnimating = false
                                    }
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                        .padding(21)
                                        .rotationEffect(.degrees(isAnimating ? 360 : 0))
                                        .animation(isAnimating ? .linear(duration: 1.0).repeatForever(autoreverses: false) : .default, value: isAnimating)
                                }
                            }
                            Spacer()
                            Button {
                                withAnimation {
                                    viewModel.isSheetExpanded = false
                                }
                            } label: {
                                Image("close-slider")
                                    .padding(23)
                            }
                        }
                        Spacer()
                    }
                }
            }
            .padding(.top, 3)
            .padding(.bottom, 7)
            .background(Color("BgMenu"))
            .cornerRadius(35)
            .shadow(radius: 10)
            .offset(y: viewModel.isSheetExpanded ? (UIScreen.main.bounds.height + keyboardObserver.keyboardHeight) * 0.1 : UIScreen.main.bounds.height * 0.90 + translation)
            .gesture(
                DragGesture()
                    .onEnded { value in
                        if value.translation.height > UIScreen.main.bounds.height * 0.25 {
                            withAnimation {
                                viewModel.isSheetExpanded = false
                            }
                        } else {
                            withAnimation {
                                viewModel.isSheetExpanded = true
                            }
                        }
                    }
            )
            .onChange(of: viewModel.isSheetExpanded) { value in
                if !value {
                    withAnimation {
                        selectedTab = 1
                    }
                }
            }
            .onAppear {
                UITableView.appearance().keyboardDismissMode = .interactive
            }

            if !viewModel.isSheetExpanded {
                Color.clear
                    .ignoresSafeArea(.container)
                    .onTapGesture {
                        withAnimation {
                            viewModel.isSheetExpanded = true
                        }
                    }
            }
        }
    }
}

struct Handlebar: View {
    var body: some View {
        Rectangle()
            .fill(Color("HandleBar"))
            .frame(width: UIScreen.main.bounds.width * 0.3, height: 7)
            .cornerRadius(7)
    }
}

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
