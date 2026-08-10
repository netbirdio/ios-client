//
//  ExitNodeSelectorCard.swift
//  NetBird
//
//  Exit node selector shown at the bottom of the connection screen.
//

import SwiftUI

#if os(iOS)

/// Card on the connection screen that shows the active exit node and opens a custom
/// dropdown with "None" plus every exit node in the network map.
///
/// This is a hand-rolled dropdown rather than `Menu`: `UIMenu` wraps an overlong item
/// title onto a second line instead of truncating it, and that wrapping ignores
/// SwiftUI's lineLimit/truncationMode since UIKit — not SwiftUI — renders the menu.
///
/// The dropdown is an overlay (not part of the VStack flow), matching the IP-details
/// dropdown elsewhere on this screen, so opening it never shifts the centered content
/// above. It opens upward: the card sits right above the tab bar, so a downward
/// dropdown would have nowhere to grow. The card's height — the upward offset — is
/// measured via `GeometryReader` rather than guessed, since a fixed guess undershoots
/// on larger Dynamic Type/Bold Text and lets the dropdown overlap the card.
///
/// The card is always part of the layout. When the network map carries no exit nodes —
/// including while the tunnel is down, where `RoutesViewModel` holds no routes at all —
/// it renders disabled rather than disappearing, so the screen doesn't reflow as routes
/// come and go.
struct ExitNodeSelectorCard: View {
    @ObservedObject var routeViewModel: RoutesViewModel
    @State private var isExpanded = false

    // Pre-measurement fallback for the first frame; corrected via GeometryReader once the
    // card is laid out.
    @State private var cardHeight: CGFloat = 72

    // @ScaledMetric so the row height tracks the user's Dynamic Type setting: rows grow
    // with larger text, and the dropdown height computed from it grows with them.
    @ScaledMetric private var rowHeight: CGFloat = 46
    private let maxDropdownHeight: CGFloat = 400

    // Computed rather than measured: a GeometryReader/preference round-trip inside the
    // ScrollView proved unreliable here (the value never arrived, leaving the dropdown at
    // its fallback height). Every row is a single truncated line of a known height, so the
    // total is exact — one row per exit node plus "None", and a 1pt divider above each node.
    private var dropdownHeight: CGFloat {
        let rows = CGFloat(exitNodes.count + 1)
        let dividers = CGFloat(exitNodes.count)
        return min(rows * rowHeight + dividers, maxDropdownHeight)
    }

    private var exitNodes: [RoutesSelectionInfo] { routeViewModel.exitNodes }
    private var isAvailable: Bool { !exitNodes.isEmpty }

    var body: some View {
        Button {
            guard isAvailable else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        } label: {
            cardLabel
                .background(
                    GeometryReader { geometry in
                        Color.clear
                            .onAppear { cardHeight = geometry.size.height }
                            .onChange(of: geometry.size.height) { cardHeight = $0 }
                    }
                )
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .accessibilityLabel("Exit node")
        .accessibilityValue(subtitle)
        .overlay(alignment: .bottom) {
            if isExpanded {
                dropdown
                    .offset(y: -(cardHeight + 8))
                    .transition(.opacity)
            }
        }
    }

    // MARK: - Label

    private var cardLabel: some View {
        HStack(spacing: 14) {
            Image("direction-sign")
                // The asset ships with a hard-coded yellow stroke; template rendering lets
                // the card tint it per state without changing how RouteCard draws it.
                .renderingMode(.template)
                .foregroundColor(iconColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("Exit node")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(titleColor)
                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundColor(Color("TextSecondary"))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.down")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color("TextSecondary"))
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color("BgPeerCard"))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color("TextSecondary").opacity(0.2))
        )
    }

    // MARK: - Dropdown

    private var dropdown: some View {
        ScrollView {
            VStack(spacing: 0) {
                dropdownRow(title: "None", isSelected: routeViewModel.selectedExitNode == nil) {
                    select(nil)
                }

                // Names come straight from the network map and are shown verbatim, however
                // verbose the admin made them ("Exit Node (raspberrypi)" and the like) —
                // lineLimit + truncationMode below keep each row to one line regardless.
                ForEach(exitNodes) { exitNode in
                    Divider().background(Color("TextSecondary").opacity(0.2))
                    dropdownRow(title: exitNode.name, isSelected: exitNode.selected) {
                        select(exitNode)
                    }
                }
            }
        }
        // An exact height, not fixedSize + maxHeight: fixedSize pins the ScrollView to its
        // full content height, which maxHeight then crops top and bottom (cutting off the
        // first and last rows) while also disabling scrolling. Sizing the frame itself
        // keeps short lists snug and lets longer ones scroll.
        .frame(height: dropdownHeight)
        .frame(width: UIScreen.main.bounds.width - 32)
        .background(Color("BgMenu"))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color("TextSecondary").opacity(0.2)))
    }

    @ViewBuilder
    private func dropdownRow(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.system(size: 15))
                    .foregroundColor(Color("TextPrimary"))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 8)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.orange)
                }
            }
            .padding(.horizontal, 14)
            // Exact, not minHeight: dropdownHeight is computed from this value, so a row
            // that grew taller than it would make the dropdown clip its last entry.
            .frame(height: rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func select(_ exitNode: RoutesSelectionInfo?) {
        routeViewModel.setExitNode(exitNode)
        withAnimation(.easeInOut(duration: 0.2)) {
            isExpanded = false
        }
    }

    // MARK: - State

    private var subtitle: String {
        guard isAvailable else { return "No exit nodes available" }
        return routeViewModel.selectedExitNode?.name ?? "None"
    }

    private var iconColor: Color {
        isAvailable ? .orange : Color("TextSecondary")
    }

    private var titleColor: Color {
        isAvailable ? Color("TextPrimary") : Color("TextSecondary")
    }
}

#endif
