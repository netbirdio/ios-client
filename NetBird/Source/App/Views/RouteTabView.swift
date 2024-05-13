//
//  RouteTabView.swift
//  NetBird
//
//  Created by Pascal Fischer on 06.05.24.
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
                        RouteSelectView(viewModel: viewModel, routeViewModel: viewModel.routeViewModel)
                    }
                } else {
                    NoRoutesView()
                }
                
                Spacer(minLength: 0)
            }
        }
        .onAppear {
            self.viewModel.getRoutes()
        }
    }
}

struct RouteSelectionHeader: View {
    @ObservedObject var routeViewModel: RoutesViewModel
    
    var body: some View {
        HStack {
            CustomTextField(placeholder: "search routes", text: self.$routeViewModel.routeFilter, secure: .constant(false))
                .padding([.top, .bottom], 10)
            Menu {
                Button(action: { self.routeViewModel.selectionFilter = "All" }) {
                    Text("All")
                }
                Button(action: { self.routeViewModel.selectionFilter = "Enabled" }) {
                    Text("Enabled")
                }
                Button(action: { self.routeViewModel.selectionFilter = "Disabled" }) {
                    Text("disabled")
                }
                
            } label: {
                Image("icon-filter")
                    .padding([.leading, .trailing], 4)
            }
        }.padding([.leading, .trailing])
    }
}


struct RouteSelectView: View {
    @ObservedObject var viewModel: ViewModel
    @ObservedObject var routeViewModel: RoutesViewModel

    var body: some View {
        ScrollView {
            ForEach(routeViewModel.filteredRoutes) { route in
                HStack {
                    HStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(viewModel.peerViewModel.peerInfo.filter({ info in
                                info.connStatus == "Connected" && info.routes.contains(route.network)
                            }).count > 0 ? Color.green : (route.selected ? Color.yellow : Color.gray.opacity(0.5)))
                                        .frame(width: 8, height: 40)
                        VStack(alignment: .leading, content: {
                            Text(route.name).foregroundColor(Color("TextPeerCard"))
                        }).padding(.leading, 5)
                        if(route.network.contains("0.0.0.0/0")){
                            Image("direction-sign")
                        }
                        Spacer()
                        Text(route.network).foregroundColor(Color("TextPeerCard")).padding(.leading, 3)
                        Toggle("", isOn: Binding(
                            get: { route.selected },
                            set: { newValue in
                                routeViewModel.toggleSelected(for: route.id)
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(SwitchToggleStyle(tint: .orange))
                        .onChange(of: route.selected) { value in
                            if value {
                                self.viewModel.selectRoute(route: route)
                            } else {
                                self.viewModel.deselectRoute(route: route)
                            }
                        }
                    }
                    .padding()
                }.background(
                    Color("BgPeerCard")
                )
                .cornerRadius(8)
            }
        }
    }
}

struct NoRoutesView: View {
    
    var body: some View {
        Group {
            Image("icon-empty-box")
                .padding(.top, UIScreen.main.bounds.height * 0.05)
            Text("It looks like there are no routes that you can choose from ...")
                .font(.system(size: 18, weight: .regular))
                .foregroundColor(Color("TextPrimary"))
                .multilineTextAlignment(.center)
                .padding(.top, UIScreen.main.bounds.height * 0.04)
                .padding([.leading, .trailing], UIScreen.main.bounds.width * 0.075)
            Link(destination: URL(string: "https://docs.netbird.io")!) {
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
                .padding(.top, UIScreen.main.bounds.height * 0.04)
            }
        }
        .padding([.leading, .trailing], UIScreen.main.bounds.width * 0.05)
    }
}
