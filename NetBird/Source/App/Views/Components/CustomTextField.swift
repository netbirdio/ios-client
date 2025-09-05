//
//  CustomTextField.swift
//  NetBird
//
//  Created by Pascal Fischer on 06.11.23.
//

import SwiftUI

struct CustomTextField: View {
    var placeholder: String
    @Binding var text: String
    @Binding var secure: Bool
    var foregroundColor: Color = .primary
    var cornerRadius: CGFloat = 8.0
    var borderColor: Color = Color("BorderTextField")
    var borderWidth: CGFloat = 1.0
    var height: CGFloat = 36.0

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color("BgTextField"))
                .frame(height: height)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(borderColor, lineWidth: borderWidth)
                )
            if secure {
                SecureField(placeholder, text: $text)
                    .foregroundColor(foregroundColor)
                    .padding(.horizontal, 8)
                    .disabled(true)
                    .autocorrectionDisabled()
            } else {
                TextField(placeholder, text: $text)
                    .foregroundColor(foregroundColor)
                    .padding(.horizontal, 8)
                    .autocorrectionDisabled()
            }
        }
    }
}

