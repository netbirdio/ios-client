//
//  JustifiedText.swift
//  NetBird
//
//  Created by Diego Romar on 01/12/25.
//

import SwiftUI
import UIKit

struct JustifiedText: View {
    var text: String
    var font: UIFont = .systemFont(ofSize: 18)
    var color: UIColor = .label

    @State private var height: CGFloat = 0

    var body: some View {
        JustifiedTextRepresentable(text: text, font: font, color: color, height: $height)
            .frame(height: height)
    }
}

private struct JustifiedTextRepresentable: UIViewRepresentable {
    var text: String
    var font: UIFont
    var color: UIColor
    @Binding var height: CGFloat

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = false
        textView.isScrollEnabled = false
        textView.textAlignment = .justified
        textView.font = font
        textView.textColor = color
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        uiView.text = text
        uiView.font = font
        uiView.textColor = color
        DispatchQueue.main.async {
            let size = uiView.sizeThatFits(CGSize(width: uiView.bounds.width, height: .greatestFiniteMagnitude))
            if size.height != height && uiView.bounds.width > 0 {
                height = size.height
            }
        }
    }
}
