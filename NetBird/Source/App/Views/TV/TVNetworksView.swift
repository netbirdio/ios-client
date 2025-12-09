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

private struct TVColors {
    static var textPrimary: Color {
        UIColor(named: "TextPrimary") != nil ? Color("TextPrimary") : .primary
    }
    static var textSecondary: Color {
        UIColor(named: "TextSecondary") != nil ? Color("TextSecondary") : .secondary
    }
    static var bgMenu: Color {
        UIColor(named: "BgMenu") != nil ? Color("BgMenu") : Color(white: 0.1)
    }
    static var bgPrimary: Color {
        UIColor(named: "BgPrimary") != nil ? Color("BgPrimary") : Color(white: 0.15)
    }
}

/// Displays the list of network routes in a tvOS-friendly format.
struct TVNetworksView: View {
    @EnvironmentObject var viewModel: ViewModel
    
    var body: some View {
        ZStack {
        TVColors.bgMenu
                .ignoresSafeArea()
            
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
            HStack {
                Text("Networks")
                    .font(.system(size: 48, weight: .bold))
                    .foregroundColor(TVColors.textPrimary)
                
                Spacer()
                
                // Stats
                Text("\(activeCount) of \(totalCount) enabled")
                    .font(.system(size: 24))
                    .foregroundColor(TVColors.textSecondary)
                
                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 28))
                        .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                        .animation(
                            isRefreshing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default,
                            value: isRefreshing
                        )
                }
                .buttonStyle(.plain)
                .padding(.leading, 30)
            }
            .padding(.horizontal, 80)
            .padding(.top, 40)
            
            TVFilterBar(
                options: ["All", "Enabled", "Disabled"],
                selected: $viewModel.routeViewModel.selectionFilter
            )
            .padding(.horizontal, 80)
            
            // Network grid
            ScrollView {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 30),
                        GridItem(.flexible(), spacing: 30)
                    ],
                    spacing: 30
                ) {
                    ForEach(viewModel.routeViewModel.filteredRoutes, id: \.id) { route in
                        TVNetworkCard(
                            route: route,
                            routeViewModel: viewModel.routeViewModel
                        )
                    }
                }
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
            HStack(spacing: 25) {
                // Status toggle indicator
                ZStack {
                    Circle()
                        .fill(route.selected ? Color.green : Color.gray.opacity(0.3))
                        .frame(width: 50, height: 50)
                    
                    Image(systemName: route.selected ? "checkmark" : "xmark")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.white)
                }
                
                // Route info
                VStack(alignment: .leading, spacing: 10) {
                    Text(route.network ?? route.name)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundColor(TVColors.textPrimary)
                        .lineLimit(1)
                    
                    if let domains = route.domains, !domains.isEmpty {
                        Text(domains.map { $0.domain }.joined(separator: ", "))
                            .font(.system(size: 20))
                            .foregroundColor(TVColors.textSecondary)
                            .lineLimit(2)
                    }
                }
                
                Spacer()
                
                Text(route.selected ? "Enabled" : "Disabled")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(route.selected ? .green : .gray)
            }
            .padding(30)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(TVColors.bgPrimary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(
                        isFocused ? Color.accentColor : (route.selected ? Color.green.opacity(0.3) : Color.clear),
                        lineWidth: isFocused ? 4 : 2
                    )
            )
            .scaleEffect(isFocused ? 1.03 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isFocused)
        }
        .buttonStyle(.plain)
        .focused($isFocused)
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
    var body: some View {
        VStack(spacing: 40) {
            Image("icon-empty-box")
                .resizable()
                .scaledToFit()
                .frame(height: 200)
            
            Text("No Networks Available")
                .font(.system(size: 40, weight: .bold))
                .foregroundColor(TVColors.textPrimary)
            
            Text("Connect to NetBird to see available networks,\nor configure network routes in your NetBird admin.")
                .font(.system(size: 26))
                .foregroundColor(TVColors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 700)
            
            // Learn more link (opens on user's phone via QR or second screen)
            Text("Visit docs.netbird.io/how-to/networks for more info")
                .font(.system(size: 22))
                .foregroundColor(.accentColor)
                .padding(.top, 20)
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


