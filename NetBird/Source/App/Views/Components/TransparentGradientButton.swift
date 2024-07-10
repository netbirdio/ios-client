//
//  TransparentButton.swift
//  NetBird
//
//  Created by Pascal Fischer on 10.07.24.
//

import SwiftUI

struct GradientBorder: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let roundedRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
        path.addRoundedRect(in: roundedRect, cornerSize: CGSize(width: 3, height: 3))
        return path
    }
}

struct GradientAnimation: ViewModifier {
    @State private var animate = false

    func body(content: Content) -> some View {
        content
            .overlay(
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color(red: 1.0, green: 0.45, blue: 0.0), // Slightly darker orange
                        Color(red: 1.0, green: 0.7, blue: 0.2), // Medium orange
                        Color(red: 1.0, green: 0.5, blue: 0.0), // Slightly darker orange
                        Color(red: 1.0, green: 0.7, blue: 0.2), // Medium orange
                        Color.white.opacity(0.5), // Subtle highlight
                        Color(red: 1.0, green: 0.45, blue: 0.0), // Slightly darker orange
                        Color(red: 1.0, green: 0.7, blue: 0.2), // Medium orange
                        Color(red: 1.0, green: 0.5, blue: 0.0), // Slightly darker orange
                        Color(red: 1.0, green: 0.7, blue: 0.2), // Medium orange
                        Color.white.opacity(0.5) // Subtle highlight
                    ]),
                    startPoint: .bottomLeading,
                    endPoint: .topTrailing
                )
                .scaleEffect(5) // Scale the gradient to cover a larger area
                .offset(x: animate ? 600 : -600, y: animate ? -200 : 200) // Larger offset for smooth animation
                .mask(content)
            )
            .onAppear {
                withAnimation(
                    Animation.linear(duration: 5.0) // Adjust animation duration for smoothness
                        .repeatForever(autoreverses: false)
                ) {
                    animate.toggle()
                }
            }
    }
}

extension View {
    func animatedTransparentGradient() -> some View {
        self.modifier(GradientAnimation())
    }
}

struct TransparentGradientButton: View {
    var text: String
    var action: () -> Void

    var body: some View {
        Button(action: {
            action()
        }) {
            ZStack {
                GradientBorder()
                    .stroke(lineWidth: 2)
                    .animatedTransparentGradient()
                    .frame(height: 44)
                
                Text(text)
                    .font(.headline)
                    .animatedTransparentGradient()
                    .frame(height: 44)
            }
        }
    }
}
