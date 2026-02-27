//
//  TVGradientBackground.swift
//  NetBird
//
//  Reusable gradient background for all tvOS screens.
//  Replaces flat black with a subtle dark gradient inspired by Apple Music.
//

import SwiftUI

#if os(tvOS)

struct TVGradientBackground: View {
    /// When true, adds a soft radial accent glow in the center (e.g. when connected).
    var showAccentGlow: Bool = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [TVColors.gradientTop, TVColors.gradientBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if showAccentGlow {
                RadialGradient(
                    colors: [Color.accentColor.opacity(0.07), .clear],
                    center: .center,
                    startRadius: 50,
                    endRadius: 600
                )
            }
        }
        .ignoresSafeArea()
    }
}

#endif
