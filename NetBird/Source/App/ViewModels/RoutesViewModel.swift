//
//  RoutesViewModel.swift
//  NetBird
//
//  Created by Pascal Fischer on 06.05.24.
//

import Foundation
import Combine

class RoutesViewModel: ObservableObject {
    @Published var networkExtensionAdapter: NetworkExtensionAdapter
    
    @Published var routeInfo: [RoutesSelectionInfo]
    @Published var selectionFilter: String
    @Published var routeFilter: String

    @Published var tappedRoute: RoutesSelectionInfo?
    @Published var selectedRouteId: UUID?
    
    init(networkExtensionAdapter: NetworkExtensionAdapter) {
        self.networkExtensionAdapter = networkExtensionAdapter
        self.routeInfo = []
        self.selectionFilter = "All"
        self.routeFilter = ""
        self.tappedRoute = nil        
        self.selectedRouteId = nil
    }
    
    var filteredRoutes: [RoutesSelectionInfo] {
        routeInfo.filter { info in
            switch selectionFilter {
            case "All": return true
            case "Enabled": return info.selected
            case "Disabled": return !info.selected
            default: return false
            }
        }
        .filter { route in
            let routeNameMatch = route.name.lowercased().contains(routeFilter.lowercased())
            let networkMatch = route.network?.contains(routeFilter) ?? false
            let domainMatch = route.domains?.contains(where: { $0.domain.contains(routeFilter) }) ?? false
            let isEmptyFilter = routeFilter.isEmpty

            return routeNameMatch || networkMatch || domainMatch || isEmptyFilter
        }
    }
    
    func toggleSelected(for routeId: UUID) {
            if let index = routeInfo.firstIndex(where: { $0.id == routeId }) {
                routeInfo[index].selected.toggle()
            }
        }
    
    func getRoutes() {
        networkExtensionAdapter.getRoutes { details in
            self.routeInfo = details.routeSelectionInfo
            print("Route count: \(details.routeSelectionInfo.count)")
        }
    }
    
    func selectRoute(route: RoutesSelectionInfo) {
        guard let index = self.routeInfo.firstIndex(where: { $0.id == route.id }) else { return }

        self.routeInfo[index].selected = true

        // Non-exit routes select independently.
        guard route.isExitNode else {
            sendSelectAndReconcile(route: route)
            return
        }

        // Exit nodes are mutually exclusive. Mirror the desktop behaviour: activating an
        // exit node deselects every other selected exit node, so 0.0.0.0/0 can't stay
        // pinned to the previously selected peer while the UI shows only the new one.
        // Non-exit route selections are left untouched. The siblings must be fully
        // deselected in the core BEFORE the new node is added: selectRoutes/deselectRoutes
        // are independent async round-trips, so firing the select without waiting lets it
        // race the deselects and the core can drop the node we just added. Wait for every
        // deselect to complete, then select.
        let siblings = routeInfo.filter { $0.id != route.id && $0.selected && $0.isExitNode }
        guard !siblings.isEmpty else {
            sendSelectAndReconcile(route: route)
            return
        }

        let group = DispatchGroup()
        for sibling in siblings {
            sibling.selected = false
            group.enter()
            networkExtensionAdapter.deselectRoutes(id: sibling.name) { _ in
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            self?.sendSelectAndReconcile(route: route)
        }
    }

    // Sends the select for `route`, then reconciles the optimistic UI selection with the
    // core's real state. Select/Deselect messages don't report the applied result (the
    // extension swallows errors and always replies "true"), so re-read the truth via
    // GetRoutes: if the core rejected the change the toggle reverts instead of leaving a
    // stale optimistic selection in place.
    private func sendSelectAndReconcile(route: RoutesSelectionInfo) {
        networkExtensionAdapter.selectRoutes(id: route.name) { [weak self] _ in
            self?.getRoutes()
        }
    }
    
    func selectAllRoutes() {
        networkExtensionAdapter.selectRoutes(id: "All") { details in
            print("selected all routes")
        }
    }
    
    func deselectRoute(route: RoutesSelectionInfo) {
        guard let index = self.routeInfo.firstIndex(where: { $0.id == route.id }) else { return }
        self.routeInfo[index].selected = false
        networkExtensionAdapter.deselectRoutes(id: route.name) { details in
            print("deselect route")
        }
    }
    
    func deselectAllRoutes() {
        networkExtensionAdapter.deselectRoutes(id: "All") { details in
            print("deselect all routes")
        }
    }
    
}

