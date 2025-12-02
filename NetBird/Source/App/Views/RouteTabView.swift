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
                if viewModel.extensionStateText == "Connected" && viewModel.routeViewModel.routeInfo.count > 0 {
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
            self.viewModel.routeViewModel.getRoutes()
        }
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
            ForEach(Array(self.routeViewModel.filteredRoutes.enumerated()), id: \.element.id) { index, route in
                RouteCard(route: route, selectedRouteId: $routeViewModel.selectedRouteId, orientationTop: index > 3, peerViewModel: peerViewModel, routeViewModel: routeViewModel)
                    .zIndex(routeViewModel.selectedRouteId == route.id ? 1 : 0)
                    .opacity(self.routeViewModel.tappedRoute == route ? 0.3 : 1.0)
            }
        }
    }
}

struct NoRoutesView: View {
    
    var body: some View {
        Group {
            Image("icon-empty-box")
                .padding(.top, Screen.height * 0.05)
            Text("It looks like there are no resources that you can connect to ...")
                .font(.system(size: 18 * Layout.fontScale, weight: .regular))
                .foregroundColor(Color("TextPrimary"))
                .multilineTextAlignment(.center)
                .padding(.top, Screen.height * 0.04)
                .padding([.leading, .trailing], Screen.width * 0.075)
            Link(destination: URL(string: "https://docs.netbird.io/how-to/networks")!) {
                Text("Learn why")
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.accentColor)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(Color.orange.darker(), lineWidth: 2)
                            )
                    )
                .padding(.top, Screen.height * 0.04)
            }
        }
        .padding([.leading, .trailing], Screen.width * 0.05)
    }
}
