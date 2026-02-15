//
//  FirstLaunchView.swift
//  NetBird
//
//  First-launch onboarding screen shown once to new users.
//

import SwiftUI

#if os(iOS)

struct FirstLaunchView: View {
    @Binding var hasCompletedOnboarding: Bool
    var onChangeServer: () -> Void

    var body: some View {
        ZStack {
            Color("BgPrimary")
                .ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                Image("onboarding")
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 200)

                onboardingText
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Button(action: {
                    hasCompletedOnboarding = true
                }) {
                    Text("Continue")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.accentColor)
                        .cornerRadius(12)
                }
                .padding(.horizontal, 32)

                Spacer()
            }
        }
    }

    @ViewBuilder
    private var onboardingText: some View {
        if #available(iOS 15.0, *) {
            let attributed: AttributedString = {
                let fullText = "By default you will connect to NetBird's cloud servers. You can change server menu to use another server."
                var result = AttributedString(fullText)
                result.font = .system(size: 17)
                result.foregroundColor = Color("TextPrimary")

                if let range = result.range(of: "change server") {
                    result[range].foregroundColor = .orange
                    result[range].font = .system(size: 17, weight: .semibold)
                    result[range].link = URL(string: "netbird://changeserver")
                }
                return result
            }()

            Text(attributed)
                .environment(\.openURL, OpenURLAction { url in
                    if url.scheme == "netbird" {
                        hasCompletedOnboarding = true
                        onChangeServer()
                        return .handled
                    }
                    return .systemAction
                })
        } else {
            (
                Text("By default you will connect to NetBird's cloud servers. You can ")
                    .font(.system(size: 17))
                    .foregroundColor(Color("TextPrimary"))
                +
                Text("change server")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.orange)
                +
                Text(" menu to use another server.")
                    .font(.system(size: 17))
                    .foregroundColor(Color("TextPrimary"))
            )
            .onTapGesture {
                hasCompletedOnboarding = true
                onChangeServer()
            }
        }
    }
}

#endif
