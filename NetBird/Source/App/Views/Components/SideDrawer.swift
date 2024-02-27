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
    
    let isIpad = UIDevice.current.userInterfaceIdiom == .pad
    
    var body: some View {
        ZStack (alignment: .leading) {
            Rectangle()
                .fill(Color("BgSideDrawer"))
                .frame(width:  UIScreen.main.bounds.width * (isIpad ? 0.4 : 0.7))
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
                    NavigationLink {
                        AdvancedView()
                    } label: {
                        HStack{
                            Image("menu-advance")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 30)
                                .padding(.trailing, 5)
                            Text("Advanced")
                                .font(.system(size: 20, weight: .regular))
                                .foregroundColor(Color("TextPrimary"))
                        }
                        .padding(.bottom, UIScreen.main.bounds.height * 0.07)
                    }
                    NavigationLink {
                        AboutView()
                    } label: {
                        HStack{
                            Image("menu-about")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 30)
                                .padding(.trailing, 5)
                            Text("About")
                                .font(.system(size: 20, weight: .regular))
                                .foregroundColor(Color("TextPrimary"))
                        }
                        .padding(.bottom, UIScreen.main.bounds.height * 0.07)
                    }
                    HStack{
                        Link(destination: URL(string: "https://docs.netbird.io")!) {
                            Image("menu-faq")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 30)
                                .padding(.trailing, 5)
                            Text("Docs")
                                .font(.system(size: 20, weight: .regular))
                                .foregroundColor(Color("TextPrimary"))
                        }
                    }
                    .buttonStyle(PlainButtonStyle()) 
                    .padding(.bottom, UIScreen.main.bounds.height * 0.07)
                    
                    Button {
                        viewModel.showChangeServerAlert = true
                        viewModel.presentSideDrawer = false
                    } label: {
                        HStack(alignment: .center, content: {
                            Image("menu-change")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 30)
                                .padding(.trailing, 5)
                            Text("Change Server")
                                .font(.system(size: 20, weight: .regular))
                                .foregroundColor(Color("TextPrimary"))
                                .padding(.top, 3)
                        })
                    }
                }
                .padding(.leading, UIScreen.main.bounds.width * 0.10)
                Spacer()
                HStack {
                    Spacer()
                    Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundColor(Color("TextPrimary"))
                    Spacer()
                }
                .padding(.bottom, UIScreen.main.bounds.height * 0.06)
            }
            .padding(.top, 10)
            .frame(width: UIScreen.main.bounds.width * (isIpad ? 0.4 : 0.7))
        }
    }
}



struct SideDrawer_Previews: PreviewProvider {
    private var isShowing = true
    static var previews: some View {
        SideMenu(viewModel: ViewModel())
    }
}
