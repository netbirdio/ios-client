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
                if viewModel.vpnDisplayState == .connected && viewModel.routeViewModel.routeInfo.count > 0 {
                    VStack {
                        RouteSelectionHeader(routeViewModel: viewModel.routeViewModel)
                        if !viewModel.routeViewModel.exitNodes.isEmpty {
                            ExitNodeSummaryRow(routeViewModel: viewModel.routeViewModel)
                        }
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
            ForEach(Array(self.routeViewModel.filteredResourceRoutes.enumerated()), id: \.element.id) { index, route in
                RouteCard(route: route, selectedRouteId: $routeViewModel.selectedRouteId, orientationTop: index > 3, routeViewModel: routeViewModel)
                    .zIndex(routeViewModel.selectedRouteId == route.id ? 1 : 0)
                    .opacity(self.routeViewModel.tappedRoute == route ? 0.3 : 1.0)
            }
        }
    }
}

struct ExitNodeSummaryRow: View {
    @ObservedObject var routeViewModel: RoutesViewModel

    var body: some View {
        NavigationLink(destination: ExitNodeSelectionView(routeViewModel: routeViewModel)) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Exit Node")
                        .foregroundColor(Color("TextPeerCard"))
                    Text(routeViewModel.selectedExitNode?.name ?? "Not Selected")
                        .font(.footnote)
                        .foregroundColor(Color("TextSecondary"))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundColor(Color("TextSecondary"))
            }
            .padding()
            .background(Color("BgPeerCard"))
            .cornerRadius(8)
        }
        .padding([.leading, .trailing])
        .padding(.bottom, 8)
    }
}

struct ExitNodeSelectionView: View {
    @ObservedObject var routeViewModel: RoutesViewModel

    var body: some View {
        List {
            Section {
                Button {
                    deselectCurrentExitNode()
                } label: {
                    HStack {
                        Text("None")
                            .foregroundColor(Color("TextPrimary"))
                        Spacer()
                        if routeViewModel.selectedExitNode == nil {
                            Image(systemName: "checkmark")
                                .foregroundColor(.orange)
                        }
                    }
                }
            }

            Section {
                ForEach(routeViewModel.exitNodes) { exitNode in
                    Button {
                        selectExitNode(exitNode)
                    } label: {
                        HStack {
                            Text(exitNode.name)
                                .foregroundColor(Color("TextPrimary"))
                            Spacer()
                            if exitNode.selected {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.orange)
                            }
                        }
                    }
                }
            } footer: {
                Text("Only one exit node can be active at a time. Selecting a new exit node deselects the previous one.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Exit Node")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func selectExitNode(_ exitNode: RoutesSelectionInfo) {
        guard !exitNode.selected else { return }
        routeViewModel.objectWillChange.send()
        routeViewModel.selectRoute(route: exitNode)
    }

    private func deselectCurrentExitNode() {
        guard let current = routeViewModel.selectedExitNode else { return }
        routeViewModel.objectWillChange.send()
        routeViewModel.deselectRoute(route: current)
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
