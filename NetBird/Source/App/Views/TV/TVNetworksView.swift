//
//  TVNetworksView.swift
//  NetBird
//
//  Networks/Routes view optimized for Apple TV.
//
//  Displays network routes that can be enabled/disabled.
//  Uses focus-based toggle instead of tap gestures.
//

import SwiftUI
import UIKit

#if os(tvOS)

/// Displays the list of network routes in a tvOS-friendly format.
struct TVNetworksView: View {
    @EnvironmentObject var viewModel: ViewModel

    var body: some View {
        ZStack {
            TVGradientBackground()

            if viewModel.extensionStateText == "Connected" &&
               viewModel.routeViewModel.routeInfo.count > 0 {
                TVNetworkListContent()
            } else {
                TVNoNetworksView()
            }
        }
        .onAppear {
            viewModel.routeViewModel.getRoutes()
        }
    }
}

struct TVNetworkListContent: View {
    @EnvironmentObject var viewModel: ViewModel
    
    /// Refresh animation state
    @State private var isRefreshing = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header (non-focusable)
            HStack {
                Text("Resources")
                    .font(.system(size: 48, weight: .bold))
                    .foregroundColor(TVColors.textPrimary)

                Spacer()

                // Stats
                Text("\(activeCount) of \(totalCount) enabled")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundColor(TVColors.textSecondary)
            }
            .padding(.horizontal, 80)
            .padding(.top, 40)

            // Filter bar with refresh button (all focusable items on same row)
            HStack {
                TVFilterBar(
                    options: ["All", "Enabled", "Disabled"],
                    selected: $viewModel.routeViewModel.selectionFilter
                )

                Spacer()

                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 28))
                        .foregroundColor(TVColors.textSecondary)
                        .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                        .animation(
                            isRefreshing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default,
                            value: isRefreshing
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 80)
            .padding(.bottom, 30)

            // Network list
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(viewModel.routeViewModel.filteredRoutes, id: \.id) { route in
                        TVNetworkCard(
                            route: route,
                            routeViewModel: viewModel.routeViewModel
                        )
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color.white.opacity(0.04))
                )
                .padding(.top, 15)
                .padding(.horizontal, 80)
                .padding(.bottom, 80)
            }
        }
    }
    
    // Computed Properties

    private var activeCount: Int {
        viewModel.routeViewModel.routeInfo.filter { $0.selected }.count
    }

    private var totalCount: Int {
        viewModel.routeViewModel.routeInfo.count
    }
    
    // Actions
    
    private func refresh() {
        isRefreshing = true
        viewModel.routeViewModel.getRoutes()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            isRefreshing = false
        }
    }
}

// Individual Network Card
struct TVNetworkCard: View {
    let route: RoutesSelectionInfo
    @ObservedObject var routeViewModel: RoutesViewModel

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: toggleRoute) {
            HStack(spacing: 20) {
                // Status toggle indicator
                ZStack {
                    Capsule()
                        .fill(route.selected ? Color.green : Color.gray.opacity(0.3))
                        .frame(width: 70, height: 40)

                    Circle()
                        .fill(Color.white)
                        .frame(width: 32, height: 32)
                        .offset(x: route.selected ? 15 : -15)
                        .animation(.easeInOut(duration: 0.2), value: route.selected)
                }

                // Route info
                VStack(alignment: .leading, spacing: 6) {
                    Text(route.name)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundColor(isFocused ? .black : TVColors.textPrimary)
                        .lineLimit(1)

                    Text(routeDisplayText)
                        .font(.system(size: 18))
                        .foregroundColor(isFocused ? .black.opacity(0.6) : TVColors.textSecondary)
                        .lineLimit(2)
                }

                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isFocused ? Color.white : Color.clear)
            )
        }
        .buttonStyle(TVSettingsButtonStyle())
        .focused($isFocused)
    }

    private var routeDisplayText: String {
        if route.network == "invalid Prefix" {
            if let domains = route.domains, domains.count > 2 {
                return "\(domains.count) Domains"
            }
            return route.domains?.map { $0.domain }.joined(separator: ", ") ?? ""
        }
        return route.network ?? ""
    }

    private func toggleRoute() {
        if route.selected {
            routeViewModel.deselectRoute(route: route)
        } else {
            routeViewModel.selectRoute(route: route)
        }
    }
}

struct TVNoNetworksView: View {
    @State private var showDocsQR = false

    var body: some View {
        VStack(spacing: 40) {
            Image("icon-empty-box")
                .resizable()
                .scaledToFit()
                .frame(height: 200)

            Text("No Resources Available")
                .font(.system(size: 44, weight: .bold))
                .foregroundColor(TVColors.textPrimary)

            Text("Connect to NetBird to see available networks,\nor configure network routes in your NetBird admin.")
                .font(.system(size: 32))
                .foregroundColor(TVColors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 700)

            Button {
                showDocsQR = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 26))
                    Text("Visit docs.netbird.io")
                        .font(.system(size: 28))
                }
                .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)
            .padding(.top, 20)
        }
        .sheet(isPresented: $showDocsQR) {
            TVQRCodeSheet(
                url: "https://docs.netbird.io/how-to/networks",
                title: "Network Resources",
                subtitle: "Scan this QR code to visit our docs"
            )
        }
    }
}

struct TVNetworksView_Previews: PreviewProvider {
    static var previews: some View {
        TVNetworksView()
            .environmentObject(ViewModel())
    }
}

#endif


