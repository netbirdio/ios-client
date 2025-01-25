//
//  RoutesViewModel.swift
//  NetBird
//
//  Created by Pascal Fischer on 06.05.24.
//

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
        networkExtensionAdapter.selectRoutes(id: route.name) { details in
            print("selected route")
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

