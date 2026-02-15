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
                .frame(height: Screen.height * 0.2)
                .padding(.top, Screen.height * 0.05)

            Text(message)
                .font(.system(size: 18 * Layout.fontScale, weight: .regular))
                .foregroundColor(Color("TextPrimary"))
                .multilineTextAlignment(.center)
                .padding(.horizontal, Screen.width * 0.075)
                .padding(.top, Screen.height * 0.04)

            if let url = learnMoreURL {
                Link(destination: url) {
                    Text("Learn why")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.accentColor)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.orange.opacity(0.8), lineWidth: 2)
                                )
                        )
                }
                .padding(.top, Screen.height * 0.04)
                .padding(.horizontal, Screen.width * 0.05)
            }
        }
        .padding(.horizontal, Screen.width * 0.05)
    }
}
