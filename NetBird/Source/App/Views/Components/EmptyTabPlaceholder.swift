//
//  EmptyTabPlaceholder.swift
//  NetBird
//
//  Reusable empty-state placeholder for tab views.
//

import SwiftUI

struct EmptyTabPlaceholder: View {
    let message: String
    let learnMoreURL: URL?

    var body: some View {
        VStack {
            Image("icon-empty-box")
                .resizable()
                .scaledToFit()
                .frame(height: 100)
                .padding(.top, Screen.height * 0.05)

            Text(message)
                .font(.system(size: 18 * Layout.fontScale, weight: .regular))
                .foregroundColor(Color("TextPrimary"))
                .multilineTextAlignment(.center)
                .padding(.horizontal, Screen.width * 0.075)
                .padding(.top, Screen.height * 0.04)

            if let url = learnMoreURL {
                AppButton("Learn why") {
                    UIApplication.shared.open(url)
                }
                .padding(.top, Screen.height * 0.04)
                .padding(.horizontal, Screen.width * 0.05)
            }
        }
        .padding(.horizontal, Screen.width * 0.05)
    }
}
