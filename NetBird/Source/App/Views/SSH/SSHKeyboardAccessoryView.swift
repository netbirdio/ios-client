//
//  SSHKeyboardAccessoryView.swift
//  NetBird
//
//  The key bar under the terminal: the keys a phone keyboard has no room for.
//  Same set and same order as the Android client's, so a screenshot of one
//  reads as the other.
//

import SwiftUI

#if os(iOS)

struct SSHKeyboardAccessoryView: View {
    let ctrlArmed: Bool
    let altArmed: Bool
    let onKey: (Data) -> Void
    let onCursor: (Character) -> Void
    let onToggleCtrl: () -> Void
    let onToggleAlt: () -> Void
    let onCopy: () -> Void
    let onPaste: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                key("Esc") { onKey(Data([0x1b])) }
                key("Tab") { onKey(Data([0x09])) }

                // An armed modifier is dimmed like a held-down key; released
                // matches the full brightness of every other key.
                key("Ctrl", armed: ctrlArmed, action: onToggleCtrl)
                key("Alt", armed: altArmed, action: onToggleAlt)

                // The three most common control codes get their own key:
                // arming Ctrl and then hitting a letter needs the soft keyboard
                // to deliver that letter, which it does not always do.
                key("^C", label: "Control C") { onKey(Data([0x03])) }
                key("^D", label: "Control D") { onKey(Data([0x04])) }
                key("^Z", label: "Control Z") { onKey(Data([0x1a])) }

                Spacer().frame(width: 8)

                key("↑", label: "Arrow up") { onCursor("A") }
                key("↓", label: "Arrow down") { onCursor("B") }
                key("←", label: "Arrow left") { onCursor("D") }
                key("→", label: "Arrow right") { onCursor("C") }

                Spacer().frame(width: 8)

                // Characters a phone keyboard buries behind a symbol page.
                key("|", label: "Pipe") { onKey(Data([UInt8(ascii: "|")])) }
                key("~", label: "Tilde") { onKey(Data([UInt8(ascii: "~")])) }
                key("/", label: "Slash") { onKey(Data([UInt8(ascii: "/")])) }
                key("-", label: "Dash") { onKey(Data([UInt8(ascii: "-")])) }
                key("_", label: "Underscore") { onKey(Data([UInt8(ascii: "_")])) }

                Spacer().frame(width: 8)

                key("Copy", action: onCopy)
                key("Paste", action: onPaste)
            }
            .padding(4)
        }
        .background(Color(white: 0.10))
    }

    private func key(_ title: String,
                     label: String? = nil,
                     armed: Bool = false,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.white)
                .frame(minWidth: 48, minHeight: 36)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.22)))
                .opacity(armed ? 0.6 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label ?? title)
    }
}

#endif
