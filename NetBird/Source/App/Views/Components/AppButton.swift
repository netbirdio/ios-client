//
//  AppButton.swift
//  NetBird
//
//  Reusable button with liquid glass on iOS 26+ and classic fallback on earlier versions.
//

import SwiftUI

struct AppButton: View {
    let title: String
    let style: Style
    let action: () -> Void

    init(_ title: String, style: Style = .default, action: @escaping () -> Void) {
        self.title = title
        self.style = style
        self.action = action
    }

    var body: some View {
        Button {
            action()
        } label: {
            ZStack {
                background
                HStack {
                    Spacer()
                    Text(title)
                        .font(style.font)
                        .foregroundColor(style.foregroundColor)
                        .lineLimit(1)
                    Spacer()
                }
            }
            .frame(height: style.height)
        }
    }

    @ViewBuilder
    private var background: some View {
        if #available(iOS 26.0, tvOS 26.0, *) {
            switch style {
            case .primary:
                Capsule()
                    .fill(Color.accentColor.opacity(0.8))
                    .glassEffect(.regular)
            case .secondary:
                Capsule()
                    .fill(Color.white.opacity(0.5))
                    .glassEffect(.regular)
            }
        } else {
            switch style {
            case .primary:
                Capsule()
                    .fill(Color.accentColor)
                    .overlay(
                        Capsule()
                            .stroke(Color.orange.opacity(0.8), lineWidth: 2)
                    )
            case .secondary:
                Capsule()
                    .fill(Color.gray.opacity(0.15))
                    .overlay(
                        Capsule()
                            .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                    )
            }
        }
    }

    enum Style {
        case primary
        case secondary

        static let `default`: Self = .primary

        var foregroundColor: Color {
            switch self {
            case .primary: return .white
            case .secondary: return .primary
            }
        }

        var font: Font {
            .body.weight(.medium)
        }

        var height: CGFloat {
            48
        }
    }
}
