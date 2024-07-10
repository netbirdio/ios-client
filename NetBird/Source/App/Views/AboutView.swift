//
//  AboutView.swift
//  NetBirdiOS
//
//  Created by Pascal Fischer on 01.08.23.
//

import SwiftUI

struct AboutView: View {
    
    @EnvironmentObject var viewModel: ViewModel
    
    @Environment(\.presentationMode) var presentationMode: Binding<PresentationMode>
    
    var body: some View {
        ZStack {
            Color("BgPage")
                .edgesIgnoringSafeArea(.bottom)
            VStack {
                Image("netbird-logo-menu")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: UIScreen.main.bounds.width * 0.4)
                    .padding(.top, UIScreen.main.bounds.height * 0.05)
                    .padding(.bottom, UIScreen.main.bounds.height * 0.04)
                HStack {
                    Text("Version")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(Color("TextPrimary"))
                    Text("\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundColor(Color("TextPrimary"))
                }
                    .padding(.bottom, UIScreen.main.bounds.height * 0.04)
                Link("License agreement", destination: URL(string: "https://netbird.io/terms")!)
                    .padding(.bottom, UIScreen.main.bounds.height * 0.04)
                    .font(.system(size: 18, weight: .medium))
                Link("Privacy policy", destination: URL(string: "https://netbird.io/privacy")!)
                    .font(.system(size: 18, weight: .medium))
                Spacer()
                TransparentGradientButton(text: "Join Beta Program") {
                    viewModel.showBetaProgramAlert.toggle()
                }
                .padding([.leading, .trailing], UIScreen.main.bounds.width * 0.20)
                .padding(.bottom, 50)
                Text("© 2023 NetBird all rights reserved")
                    .foregroundColor(Color.white)
                    .padding(.bottom, UIScreen.main.bounds.height * 0.01)
            }
            if viewModel.showBetaProgramAlert {
                Color.black.opacity(0.4)
                    .edgesIgnoringSafeArea(.all)
                    .onTapGesture {
                        viewModel.buttonLock = true
                        viewModel.showBetaProgramAlert = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            viewModel.buttonLock = false
                        }
                    }
                
                BetaProgramAlert(viewModel: viewModel, isPresented: $viewModel.showBetaProgramAlert)
                    .frame(maxWidth: UIScreen.main.bounds.width * 0.9)
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .navigationBarItems(leading: CustomBackButton(text: "About", action: {
            presentationMode.wrappedValue.dismiss()
        }))
    }
}

struct BetaProgramAlert: View {
    @StateObject var viewModel: ViewModel
    @Binding var isPresented: Bool
    
    var body: some View {
        VStack(spacing: 20) {
            Image("exclamation-circle")
                .padding(.top, 20)
            Text("Joining TestFlight Beta")
                .font(.title)
                .foregroundColor(Color("TextAlert"))
            Text("By signing up for the TestFlight you will be receiving the new updates early and can give us valuable feedback before the official release.")
                .foregroundColor(Color("TextAlert"))
                .multilineTextAlignment(.center)
            SolidButton(text: "Sign Up") {
                if let url = URL(string: "https://testflight.apple.com/join/jISzXOP8") {
                    UIApplication.shared.open(url)
                }
                isPresented.toggle()
            }
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

struct AboutView_Previews: PreviewProvider {
    static var previews: some View {
        AboutView()
    }
}
