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

                AppButton("Continue") {
                    hasCompletedOnboarding = true
                }
                .padding(.horizontal, 32)

                Spacer()
            }
        }
    }

    private var onboardingText: some View {
        let attributed: AttributedString = {
            let fullText = "By default you will connect to NetBird's cloud servers. Visit the Change server menu to use another server."
            var result = AttributedString(fullText)
            result.font = .system(size: 17)
            result.foregroundColor = Color("TextPrimary")

            if let range = result.range(of: "Change server") {
                result[range].foregroundColor = .orange
                result[range].font = .system(size: 17, weight: .semibold)
                result[range].link = URL(string: "netbird://changeserver")
            }
            return result
        }()

        return Text(attributed)
            .environment(\.openURL, OpenURLAction { url in
                if url.scheme == "netbird" {
                    hasCompletedOnboarding = true
                    onChangeServer()
                    return .handled
                }
                return .systemAction
            })
    }
}

#endif
