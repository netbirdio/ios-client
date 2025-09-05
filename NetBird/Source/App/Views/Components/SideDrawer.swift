//
//  SideDrawer.swift
//  NetBirdiOS
//
//  Created by Pascal Fischer on 01.08.23.
//

import SwiftUI

struct SideDrawer: View {
    @StateObject var viewModel: ViewModel
    @Binding var isShowing: Bool
    var edgeTransition: AnyTransition = .move(edge: .leading)
    
    var body: some View {
        ZStack(alignment: .leading) {
                    if (isShowing) {
                        Color.black
                            .opacity(0.3)
                            .ignoresSafeArea()
                            .onTapGesture {
                                isShowing.toggle()
                            }
                        SideMenu(viewModel: viewModel)
                            .transition(edgeTransition)
                            .background(
                                Color.clear
                            )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .ignoresSafeArea()
                .animation(.easeInOut, value: isShowing)
    }
}

struct SideMenu: View {
    @StateObject var viewModel: ViewModel

    private let isIpad = UIDevice.current.userInterfaceIdiom == .pad

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(Color("BgSideDrawer"))
                .frame(width: UIScreen.main.bounds.width * (isIpad ? 0.4 : 0.7), height: UIScreen.main.bounds.height)
                .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: 3)

            VStack(alignment: .leading, spacing: UIScreen.main.bounds.width * 0.05) {
                HStack {
                    Spacer()
                    Image("netbird-logo-menu")
                    Spacer()
                }
                .padding(.top, UIScreen.main.bounds.height * 0.05)
                .padding(.bottom, UIScreen.main.bounds.height * 0.11)

                Group {
                    menuNavigationLink(
                        imageName: "menu-advance",
                        label: "Advanced",
                        destination: AdvancedView()
                    )

                    menuNavigationLink(
                        imageName: "menu-about",
                        label: "About",
                        destination: AboutView()
                    )

                    menuLink(
                        imageName: "menu-faq",
                        label: "Docs",
                        url: URL(string: "https://docs.netbird.io")
                    )

                    changeServerButton()
                }
                .padding(.leading, UIScreen.main.bounds.width * 0.10)

                Spacer()

                HStack {
                    Spacer()
                    Text("Version \(appVersion)")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundColor(Color("TextPrimary"))
                    Spacer()
                }
                .padding(.bottom, UIScreen.main.bounds.height * 0.06)
            }
            .padding(.top, 10)
            .frame(width: UIScreen.main.bounds.width * (isIpad ? 0.4 : 0.7), height: UIScreen.main.bounds.height)
        }
    }

    private func menuNavigationLink<Destination: View>(imageName: String, label: String, destination: Destination) -> some View {
        NavigationLink(destination: destination) {
            HStack {
                Image(imageName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 30)
                    .padding(.trailing, 5)
                Text(label)
                    .font(.system(size: 20, weight: .regular))
                    .foregroundColor(Color("TextPrimary"))
            }
            .padding(.bottom, UIScreen.main.bounds.height * 0.07)
        }
    }

    private func menuLink(imageName: String, label: String, url: URL?) -> some View {
        Group {
            if let url = url {
                Link(destination: url) {
                    HStack {
                        Image(imageName)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 30)
                            .padding(.trailing, 5)
                        Text(label)
                            .font(.system(size: 20, weight: .regular))
                            .foregroundColor(Color("TextPrimary"))
                    }
                }
                .padding(.bottom, UIScreen.main.bounds.height * 0.07)
                .buttonStyle(PlainButtonStyle())
            } else {
                EmptyView()
            }
        }
    }

    private func changeServerButton() -> some View {
        Button {
            viewModel.showChangeServerAlert = true
            viewModel.presentSideDrawer = false
        } label: {
            HStack {
                Image("menu-change")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 30)
                    .padding(.trailing, 5)
                Text("Change Server")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundColor(Color("TextPrimary"))
                    .padding(.top, 3)
            }
        }
        .padding(.bottom, UIScreen.main.bounds.height * 0.07)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }
}

struct SideDrawer_Previews: PreviewProvider {
    private var isShowing = true
    static var previews: some View {
        SideMenu(viewModel: ViewModel())
    }
}
