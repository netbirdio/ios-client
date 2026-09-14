//
//  TVExitNodeSelector.swift
//  NetBird
//
//  Exit node selector shown on the tvOS connection screen.
//

import SwiftUI

#if os(tvOS)

/// tvOS counterpart of the connection screen's `ExitNodeSelectorCard`. It shares the same
/// model rules — exit nodes live outside the resources list, only one can be active, and
/// "None" clears the current one.
///
/// Where iOS expands a dropdown in place, this opens the list modally. The connection
/// screen is a centred layout, so a list growing inline would shove the toggle and the
/// stats bar out of position, and tvOS has no pointer to dismiss a floating overlay with;
/// a sheet is the platform's normal way to pick from a set of options.
///
/// The card stays in the layout even with nothing to choose from, rendering disabled, so
/// the screen doesn't reflow as routes come and go.
struct TVExitNodeSelector: View {
    @ObservedObject var routeViewModel: RoutesViewModel

    @State private var isPresentingList = false
    @FocusState private var isFocused: Bool

    private var exitNodes: [RoutesSelectionInfo] { routeViewModel.exitNodes }
    private var isAvailable: Bool { !exitNodes.isEmpty }

    var body: some View {
        Button {
            isPresentingList = true
        } label: {
            card
        }
        .buttonStyle(TVSettingsButtonStyle())
        .focused($isFocused)
        .disabled(!isAvailable)
        .accessibilityLabel("Exit node")
        .accessibilityValue(subtitle)
        .sheet(isPresented: $isPresentingList) {
            TVExitNodeListSheet(routeViewModel: routeViewModel)
        }
        // Losing the tunnel clears every route, which would leave the open sheet listing
        // nothing but "None".
        .onChange(of: isAvailable) { available in
            guard !available, isPresentingList else { return }
            isPresentingList = false
        }
    }

    private var card: some View {
        HStack(spacing: 18) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 26))
                .foregroundColor(isFocused ? .black : iconColor)

            VStack(alignment: .leading, spacing: 4) {
                Text("Exit node")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(isFocused ? .black.opacity(0.6) : TVColors.textSecondary)

                Text(subtitle)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(isFocused ? .black : titleColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 16)

            Image(systemName: "chevron.right")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(isFocused ? .black : TVColors.textSecondary)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(isFocused ? Color.white : Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Color.white.opacity(isFocused ? 0 : 0.08), lineWidth: 1)
                )
        )
    }

    private var subtitle: String {
        guard isAvailable else { return "No exit nodes available" }
        return routeViewModel.selectedExitNode?.name ?? "None"
    }

    private var iconColor: Color {
        isAvailable ? .orange : TVColors.textSecondary
    }

    private var titleColor: Color {
        isAvailable ? TVColors.textPrimary : TVColors.textSecondary
    }
}

/// Modal list of exit nodes: "None" plus every node in the network map, single selection.
struct TVExitNodeListSheet: View {
    @ObservedObject var routeViewModel: RoutesViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            TVGradientBackground()

            VStack(alignment: .leading, spacing: 20) {
                Text("Exit node")
                    .font(.system(size: 48, weight: .bold))
                    .foregroundColor(TVColors.textPrimary)

                Text("Only one exit node can be active at a time.")
                    .font(.system(size: 26))
                    .foregroundColor(TVColors.textSecondary)
                    .padding(.bottom, 10)

                ScrollView {
                    LazyVStack(spacing: 4) {
                        TVExitNodeRow(
                            title: "None",
                            isSelected: routeViewModel.selectedExitNode == nil
                        ) {
                            select(nil)
                        }

                        ForEach(routeViewModel.exitNodes) { exitNode in
                            TVExitNodeRow(
                                title: exitNode.name,
                                isSelected: exitNode.selected
                            ) {
                                select(exitNode)
                            }
                        }
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: TVLayout.cornerRadiusMedium)
                            .fill(Color.white.opacity(0.04))
                    )
                }
            }
            .padding(.horizontal, TVLayout.contentPadding)
            .padding(.vertical, 60)
        }
    }

    private func select(_ exitNode: RoutesSelectionInfo?) {
        routeViewModel.setExitNode(exitNode)
        dismiss()
    }
}

/// One entry in the exit node list.
struct TVExitNodeRow: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 20) {
                Text(title)
                    .font(.system(size: 26, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isFocused ? .black : TVColors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 12)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(isFocused ? .black : .orange)
                        // Decorative: the selection is carried as a trait instead, so
                        // VoiceOver reads "<name>, selected" rather than "<name>, checkmark".
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isFocused ? Color.white : Color.clear)
            )
        }
        .buttonStyle(TVSettingsButtonStyle())
        .focused($isFocused)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#endif
