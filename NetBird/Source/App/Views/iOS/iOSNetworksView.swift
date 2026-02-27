//
//  iOSNetworksView.swift
//  NetBird
//
//  Networks tab: full-screen wrapper around RouteTabView.
//

import SwiftUI

#if os(iOS)

struct iOSNetworksView: View {
    @EnvironmentObject var viewModel: ViewModel
    @State private var isAnimating = false

    var body: some View {
        ZStack {
            Color("BgMenu")
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Text(enabledCount + " of " + totalCount)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(Color("TextSecondary"))
                    Text("Resources connected")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundColor(Color("TextSecondary"))
                    Spacer()

                    Button {
                        isAnimating = true
                        viewModel.routeViewModel.getRoutes()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) {
                            self.isAnimating = false
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundColor(Color("TextSecondary"))
                            .rotationEffect(.degrees(isAnimating ? 360 : 0))
                            .animation(isAnimating ? .linear(duration: 1.0).repeatForever(autoreverses: false) : .default, value: isAnimating)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 16)
                .padding(.bottom, 8)

                RouteTabView()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarHidden(true)
    }

    private var enabledCount: String {
        guard viewModel.vpnDisplayState == .connected else { return "0" }
        return viewModel.routeViewModel.routeInfo.filter { $0.selected }.count.description
    }

    private var totalCount: String {
        guard viewModel.vpnDisplayState == .connected else { return "0" }
        return viewModel.routeViewModel.routeInfo.count.description
    }
}

#endif
