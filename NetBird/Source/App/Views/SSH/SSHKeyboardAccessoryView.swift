//
//  SSHKeyboardAccessoryView.swift
//  NetBird
//

import SwiftUI

#if os(iOS)

struct SSHKeyboardAccessoryView: View {
    let onInput: (Data) -> Void
    let onCopy: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                accessoryKey("ESC")  { send("\u{1b}") }
                accessoryKey("TAB")  { send("\t") }
                accessoryKey("^C")   { send("\u{03}") }
                accessoryKey("^D")   { send("\u{04}") }
                accessoryKey("^Z")   { send("\u{1a}") }

                Divider().frame(height: 22).padding(.horizontal, 2)

                accessoryKey("↑") { send("\u{1b}[A") }
                accessoryKey("↓") { send("\u{1b}[B") }
                accessoryKey("←") { send("\u{1b}[D") }
                accessoryKey("→") { send("\u{1b}[C") }

                Divider().frame(height: 22).padding(.horizontal, 2)

                accessoryKey("|")  { send("|") }
                accessoryKey("~")  { send("~") }
                accessoryKey("/")  { send("/") }
                accessoryKey("-")  { send("-") }
                accessoryKey("_")  { send("_") }

                Divider().frame(height: 22).padding(.horizontal, 2)

                accessoryKey("Copy", systemImage: "doc.on.doc") { onCopy() }
                accessoryKey("Paste", systemImage: "doc.on.clipboard") { paste() }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .frame(height: 44)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder
    private func accessoryKey(_ label: String, systemImage: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let icon = systemImage {
                    Label(label, systemImage: icon)
                        .labelStyle(.iconOnly)
                } else {
                    Text(label)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                }
            }
            .foregroundColor(.primary)
            .frame(minWidth: 36, minHeight: 32)
            .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private func send(_ string: String) {
        onInput(Data(string.utf8))
    }

    private func paste() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        onInput(Data(text.utf8))
    }
}

#endif
