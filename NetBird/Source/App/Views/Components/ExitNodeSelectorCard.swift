//
//  ExitNodeSelectorCard.swift
//  NetBird
//
//  Exit node selector shown at the bottom of the connection screen.
//

import SwiftUI

#if os(iOS)

/// Card on the connection screen that shows the active exit node and opens a dropdown
/// with "None" plus every exit node in the network map.
///
/// The card is always part of the layout. When the network map carries no exit nodes —
/// including while the tunnel is down, where `RoutesViewModel` holds no routes at all —
/// it renders disabled rather than disappearing, so the screen doesn't reflow as routes
/// come and go.
struct ExitNodeSelectorCard: View {
    @ObservedObject var routeViewModel: RoutesViewModel

    private var exitNodes: [RoutesSelectionInfo] { routeViewModel.exitNodes }
    private var isAvailable: Bool { !exitNodes.isEmpty }

    var body: some View {
        Menu {
            Button {
                routeViewModel.setExitNode(nil)
            } label: {
                menuItem(title: "None", isSelected: routeViewModel.selectedExitNode == nil)
            }

            // Names come straight from the network map and are shown verbatim, however
            // verbose the admin made them ("Exit Node (raspberrypi)" and the like).
            ForEach(exitNodes) { exitNode in
                Button {
                    routeViewModel.setExitNode(exitNode)
                } label: {
                    menuItem(title: exitNode.name, isSelected: exitNode.selected)
                }
            }
        } label: {
            cardLabel
        }
        .disabled(!isAvailable)
        .accessibilityLabel("Exit node")
        .accessibilityValue(subtitle)
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

    @ViewBuilder
    private func menuItem(title: String, isSelected: Bool) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
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
