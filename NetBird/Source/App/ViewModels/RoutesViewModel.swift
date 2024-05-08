//
//  RoutesViewModel.swift
//  NetBird
//
//  Created by Pascal Fischer on 06.05.24.
//

import Combine

class RoutesViewModel: ObservableObject {
    @Published var routeInfo: [RoutesSelectionInfo] = []
    @Published var selectionFilter: String = "All"
    @Published var routeFilter: String = ""

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
            route.name.lowercased().contains(routeFilter.lowercased()) ||
            route.network.contains(routeFilter) ||
            routeFilter.isEmpty
        }
    }
    
    func toggleSelected(for routeId: UUID) {
            if let index = routeInfo.firstIndex(where: { $0.id == routeId }) {
                routeInfo[index].selected.toggle()
            }
        }

}

