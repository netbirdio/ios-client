//
//  MainView.swift
//  NetBirdiOS
//
//  Created by Pascal Fischer on 01.08.23.
//

import SwiftUI
import Lottie
import NetworkExtension

struct MainView: View {
    @EnvironmentObject var viewModel: ViewModel
    @State private var isSheetshown = true
    @State private var isSheetExpanded = false
    @State private var animationKey: UUID = UUID()
    
    let isIpad = UIDevice.current.userInterfaceIdiom == .pad
    
    init() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(named: "BgNavigationBar")

        // Customize the title text color
        appearance.titleTextAttributes = [.foregroundColor: UIColor.white]
        appearance.largeTitleTextAttributes = [.foregroundColor: UIColor.white]

        // Set the appearance for when the navigation bar is displayed regularly
        UINavigationBar.appearance().standardAppearance = appearance

        // Set the appearance for when the navigation bar has a collapsed state
        UINavigationBar.appearance().compactAppearance = appearance // Optional

        // Set the appearance for when the navigation bar is displayed in a scroll edge context
        UINavigationBar.appearance().scrollEdgeAppearance = appearance // For iOS 15 and later
    }
    
    var body: some View {
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
                        Image("bg-bottom")
                            .resizable(resizingMode: .stretch)
                            .aspectRatio(contentMode: .fill)
                            .padding(.top, UIScreen.main.bounds.height * (isIpad ? 0.32 : 0.19))
                            .frame(width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.width * 1.33)
                            .edgesIgnoringSafeArea(.bottom)
                    }
                    VStack {
                        Text(viewModel.fqdn)
                            .foregroundColor(Color("TextSecondary"))
                            .font(.system(size: 20, weight: .regular))
                            .padding(.top, UIScreen.main.bounds.height * 0.11)
                            .padding(.bottom, 5)
                        Text(viewModel.ip)
                            .foregroundColor(Color("TextSecondary"))
                            .font(.system(size: 20, weight: .regular))
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
                        #if DEBUG
                        Spacer()
                        Button("print logs") {
                            let fileManager = FileManager.default
                            let groupURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: "group.io.netbird.app")
                            let logURL = groupURL?.appendingPathComponent("logfile.log")
                            printLogContents(from: logURL!)
                        }
                        #endif
                        Spacer()
                        Button(action: {
                            if !viewModel.buttonLock {
                                if viewModel.extensionState == .disconnected {
                                    viewModel.connect()
                                } else if viewModel.extensionState == .connecting || viewModel.statusDetails.managementStatus == .connecting || viewModel.extensionState == .connected {
                                    print("Trying to stop extenison")
                                    viewModel.close()
                                }
                            }
                        }) {
                            CustomLottieView(extensionStatus: $viewModel.extensionState, engineStatus: $viewModel.statusDetails.managementStatus, connectPressed: $viewModel.connectPressed, disconnectPressed: $viewModel.disconnectPressed, viewModel: viewModel)
                                .id(animationKey)
                                .frame(width: UIScreen.main.bounds.width * 0.79, height: UIScreen.main.bounds.width * 0.79)
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
                        Spacer()
                    }
                    .padding()
                    SheetView(isSheetExpanded: $isSheetExpanded, peerInfo: viewModel.statusDetails.peerInfo)
                    SideDrawer(viewModel: viewModel, isShowing: $viewModel.presentSideDrawer)
                    NavigationLink("", destination: ServerView(), isActive: $viewModel.navigateToServerView)
                        .hidden()
                    if viewModel.networkExtensionAdapter.showBrowser && viewModel.networkExtensionAdapter.loginURL != nil && URL(string: viewModel.networkExtensionAdapter.loginURL!) != nil {
                        SafariView(isPresented: $viewModel.networkExtensionAdapter.showBrowser,
                                   url: URL(string: viewModel.networkExtensionAdapter.loginURL!)!,
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
                    // diabled for now as it is generating to much false positives
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
                            if viewModel.showCopiedAlert {
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
                                .animation(.default, value: viewModel.showCopiedAlert)
                                .zIndex(1)
                           }
                            if viewModel.showCopiedInfoAlert {
                               Text("Double-tap to copy!")
                                   .foregroundColor(.white)
                                   .font(.headline)
                                   .padding(5)
                                   .background(Color.black.opacity(0.5))
                                   .cornerRadius(8)
                                   .transition(AnyTransition.opacity.combined(with: .move(edge: .top)))
                                   .animation(.default, value: viewModel.showCopiedInfoAlert)
                                   .zIndex(1)
                           }
                        }
                        .padding(.bottom, 40)
                    }
                } else {
                    Image("netbird-logo-menu")
                        .resizable()
                        .scaledToFit()
                        .frame(width: UIScreen.main.bounds.width * 0.8)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarHidden(true)
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}

struct SheetView: View {
    @EnvironmentObject var viewModel: ViewModel
    
    @Binding var isSheetExpanded: Bool
    var peerInfo: [PeerInfo]
    @GestureState private var translation: CGFloat = 0
    
    @State private var peerFilter: String = ""
    @State private var selectionFilter: String = "All"
    @State private var showDropdown: Bool = false
    
    @State private var tappedPeer: PeerInfo? = nil
    
    let isIpad = UIDevice.current.userInterfaceIdiom == .pad

    var filteredPeers: [PeerInfo] {
        return peerInfo
            .filter {
                switch selectionFilter {
                case "All": return true
                case "Connected": return $0.connStatus == "Connected"
                case "Disconnected": return $0.connStatus == "Disconnected"
                default: return false
                }
            }
            .filter {
                $0.fqdn.lowercased().contains(peerFilter.lowercased()) ||
                $0.ip.contains(peerFilter) ||
                peerFilter.isEmpty
            }
    }

    
    var body: some View {
        ZStack {
            ZStack {
                VStack {
                    Button {
                        withAnimation(.linear(duration: 0.2)) {
                            isSheetExpanded.toggle()
                        }
                    } label: {
                        Handlebar().padding(.top, 5)
                    }
                    HStack {
                        Text((viewModel.extensionStateText != "Connected" ? "0" : peerInfo.filter({ info in
                            info.connStatus == "Connected"
                        }).count.description) + " of " + (viewModel.extensionStateText != "Connected" ? "0" : peerInfo.count.description)).font(.system(size: 18, weight: .bold))
                            .foregroundColor(Color("TextSecondary"))
                        Text("Peers connected")
                            .font(.system(size: 18, weight: .regular))
                            .foregroundColor(Color("TextSecondary"))
                    }
                    .padding(.top, UIScreen.main.bounds.height * (isIpad ? 0.02 : 0.005))
                    .padding(.bottom, 15)
                    if viewModel.extensionStateText == "Connected" && peerInfo.count > 0 {
                        VStack {
                            HStack {
                                CustomTextField(placeholder: "search peers", text: $peerFilter, secure: .constant(false))
                                    .padding([.top, .bottom], 10)
                                Menu {
                                    Button(action: { selectionFilter = "All" }) {
                                        Text("All")
                                    }
                                    
                                    Button(action: { selectionFilter = "Connected" }) {
                                        Text("Connected")
                                    }
                                    Button(action: { selectionFilter = "Disconnected" }) {
                                        Text("Disconnected")
                                    }
                                    
                                } label: {
                                    Image("icon-filter")
                                        .padding([.leading, .trailing], 4)
                                }
                            }.padding([.leading, .trailing])
                            ZStack {
                                ScrollView {
                                    ForEach(filteredPeers) { peer in
                                        ZStack {
                                            PeerCard(peer: peer)
                                                .opacity(tappedPeer == peer ? 0.3 : 1.0)
                                                .onTapGesture(count: 2) {
                                                    tappedPeer = peer
                                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                                        withAnimation {
                                                            tappedPeer = nil
                                                        }
                                                    }
                                                    
                                                    print("Copied to clipboard")
                                                    UIPasteboard.general.string = peer.fqdn
                                                    viewModel.showCopiedAlert = true

                                                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                                        withAnimation {
                                                            viewModel.showCopiedAlert = false
                                                        }
                                                    }
                                                }
                                                .onTapGesture {
                                                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                                                    print("show notication")
                                                    viewModel.showCopiedInfoAlert = true
                                                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                                        withAnimation {
                                                            viewModel.showCopiedInfoAlert = false
                                                        }
                                                    }
                                                }
                                                .padding([.top,.bottom], 2)
                                        }
                                    }
                                }
                                .frame(height: UIScreen.main.bounds.height * 0.70)
                                .padding(.bottom, 1)
                            }
                        }
                    } else {
                        Group {
                            Image("icon-empty-box")
                                .padding(.top, UIScreen.main.bounds.height * 0.05)
                            Text("It looks like there are no machines that you can connect to...")
                                .font(.system(size: 18, weight: .regular))
                                .foregroundColor(Color("TextPrimary"))
                                .multilineTextAlignment(.center)
                                .padding(.top, UIScreen.main.bounds.height * 0.04)
                                .padding([.leading, .trailing], UIScreen.main.bounds.width * 0.075)
                            Link(destination: URL(string: "https://docs.netbird.io")!) {
                                Text("Learn why")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                    .padding()
                                    .frame(maxWidth: .infinity) // Span the whole width
                                    .background(
                                        RoundedRectangle(cornerRadius: 3)
                                            .fill(Color.accentColor)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 3)
                                                    .stroke(Color.orange.darker(), lineWidth: 2)
                                            )
                                    )
                                .padding(.top, UIScreen.main.bounds.height * 0.04)
                            }
                        }
                        .padding([.leading, .trailing], UIScreen.main.bounds.width * 0.05)
                    }
                    Spacer()
                }
                if isSheetExpanded {
                    VStack {
                        HStack {
                            Spacer()
                            Button {
                                withAnimation {
                                    isSheetExpanded = false
                                }
                            } label: {
                                Image("close-slider")
                                    .padding(25)
                            }
                        }
                        Spacer()
                    }
                }
            }
            .padding(.top, 3)
            .padding(.bottom, 7)
            .frame(maxWidth: .infinity, maxHeight: UIScreen.main.bounds.height)
            .background(Color("BgMenu"))
            .cornerRadius(35)
            .shadow(radius: 10)
            .offset(y: isSheetExpanded ? UIScreen.main.bounds.height * 0.1 : UIScreen.main.bounds.height * 0.90 + translation)
            .gesture(
                DragGesture()
                    .updating($translation, body: { value, state, _ in
                        state = value.translation.height
                    })
                    .onEnded({ value in
                        if value.translation.height > UIScreen.main.bounds.height * 0.25 {
                            withAnimation {
                                isSheetExpanded = false
                            }
                        } else {
                            withAnimation {
                                isSheetExpanded = true
                            }
                        }
                    })
            )
            .onTapGesture {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
            
            // Add a transparent background to enable interaction with the rest of the screen when collapsed
            if !isSheetExpanded {
                Color.clear
                    .ignoresSafeArea(.container)
                    .onTapGesture {
                        withAnimation {
                            isSheetExpanded = true
                        }
                    }
            }
        }
        .frame(maxHeight: .infinity) // Make sure the sheet can take up the entire screen height
        .ignoresSafeArea(.keyboard) // Ignore the keyboard to prevent conflicts with the sheet layout
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
                viewModel.close()
                viewModel.clearDetails()
                isPresented.toggle()
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
                    .frame(maxWidth: .infinity) // Span the whole width
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
