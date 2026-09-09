//
//  RouteTabView.swift
//  NetBird
//
//  Created by Pascal Fischer on 06.05.24.
//
//  Shared between iOS and tvOS.
//  Uses Screen helper for platform-independent sizing.
//

import SwiftUI

struct RouteTabView: View {
    @EnvironmentObject var viewModel: ViewModel
    
    var body: some View {
        ZStack {
            Color("BgMenu")
            VStack {
                Spacer(minLength: 0)
                if viewModel.mdmRestrictions.mdm.disableClientRoutes {
                    // The engine installs no client routes under this policy,
                    // so selecting them would change nothing. Say so instead
                    // of showing an empty list that looks like a failure.
                    RoutesDisabledByPolicyView()
                } else if viewModel.vpnDisplayState == .connected && viewModel.routeViewModel.routeInfo.count > 0 {
                    VStack {
                        RouteSelectionHeader(routeViewModel: viewModel.routeViewModel)
                        RouteListView(viewModel: viewModel, routeViewModel: viewModel.routeViewModel, peerViewModel: viewModel.peerViewModel)
                    }
                } else {
                    NoRoutesView()
                }
                
                Spacer(minLength: 0)
            }
        }
        .onAppear {
            self.viewModel.refreshMDMRestrictions()
            self.viewModel.routeViewModel.getRoutes()
        }
    }
}

struct RoutesDisabledByPolicyView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.largeTitle)
                .foregroundColor(Color("TextSecondary"))
            Text("Network routes are managed by your organization")
                .font(.system(size: 18 * Layout.fontScale))
                .foregroundColor(Color("TextPrimary"))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, Screen.width * 0.1)
    }
}

struct RouteSelectionHeader: View {
    @ObservedObject var routeViewModel: RoutesViewModel
    
    var body: some View {
        HStack {
            CustomTextField(placeholder: "search resources", text: self.$routeViewModel.routeFilter, secure: .constant(false))
                .padding([.top, .bottom], 10)
            Menu {
                Button(action: { self.routeViewModel.selectionFilter = "All" }) {
                    Text("All")
                }
                Button(action: { self.routeViewModel.selectionFilter = "Enabled" }) {
                    Text("Enabled")
                }
                Button(action: { self.routeViewModel.selectionFilter = "Disabled" }) {
                    Text("Disabled")
                }
            } label: {
                Image("icon-filter")
                    .padding([.leading, .trailing], 4)
            }
        }.padding([.leading, .trailing])
    }
}


struct RouteListView: View {
    @ObservedObject var viewModel: ViewModel
    @ObservedObject var routeViewModel: RoutesViewModel
    @ObservedObject var peerViewModel: PeerViewModel

    var body: some View {
        ScrollView {
            ForEach(Array(self.routeViewModel.filteredResourceRoutes.enumerated()), id: \.element.id) { index, route in
                RouteCard(route: route, selectedRouteId: $routeViewModel.selectedRouteId, orientationTop: index > 3, routeViewModel: routeViewModel)
                    .zIndex(routeViewModel.selectedRouteId == route.id ? 1 : 0)
                    .opacity(self.routeViewModel.tappedRoute == route ? 0.3 : 1.0)
            }
        }
    }
}

struct NoRoutesView: View {
    var body: some View {
        EmptyTabPlaceholder(
            message: "It looks like there are no resources that you can connect to...",
            learnMoreURL: URL(string: "https://docs.netbird.io/how-to/networks")
        )
    }
}
