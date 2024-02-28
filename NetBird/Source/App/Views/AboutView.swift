//
//  AboutView.swift
//  NetBirdiOS
//
//  Created by Pascal Fischer on 01.08.23.
//

import SwiftUI

struct AboutView: View {
    
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
                Text("© 2023 NetBird all rights reserved")
                    .foregroundColor(Color.white)
                    .padding(.bottom, UIScreen.main.bounds.height * 0.01)
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

struct AboutView_Previews: PreviewProvider {
    static var previews: some View {
        AboutView()
    }
}
