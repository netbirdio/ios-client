//
//  TVPreSharedKeyButton.swift
//  NetBird
//
//  Styled button for tvOS alert dialogs with focus glow and scale animation.
//

import SwiftUI

#if os(tvOS)

struct TVPreSharedKeyButton: View {
    let title: String
    /// Pass `nil` for an outlined (cancel) style, or a color for a filled style.
    let color: Color?
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 24, weight: color != nil ? .semibold : .regular))
                .foregroundColor(isFocused ? .black : .white)
                .padding(.horizontal, color != nil ? 50 : 40)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(buttonFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(borderStroke, lineWidth: isFocused ? 0 : 2)
                )
        }
        .buttonStyle(TVSettingsButtonStyle())
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.08 : 1.0)
        .shadow(
            color: shadowColor,
            radius: isFocused ? 16 : 0,
            y: isFocused ? 6 : 0
        )
        .animation(.easeInOut(duration: 0.2), value: isFocused)
    }

    private var buttonFill: Color {
        if isFocused {
            return .white
        }
        return color ?? Color.white.opacity(0.08)
    }

    private var borderStroke: Color {
        if isFocused || color != nil {
            return .clear
        }
        return Color.white.opacity(0.5)
    }

    private var shadowColor: Color {
        guard isFocused else { return .clear }
        return (color ?? .white).opacity(0.4)
    }
}

#endif
