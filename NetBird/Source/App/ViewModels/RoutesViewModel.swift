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

    /// Bumped by every exit node mutation. Each one captures the value at its start and
    /// re-checks it in its async continuation, so an operation the user has already
    /// superseded drops its pending select/reconcile instead of applying it late. Without
    /// this, switching exit nodes twice in quick succession races: the two deselect →
    /// select chains are independent round-trips, and the older chain's select can land
    /// last, leaving the core routing through a node the user already replaced.
    /// Main-thread only, matching every caller.
    private var exitNodeGeneration = 0

    /// Bumped by every route read and by `clearRoutes()`. A GetRoutes reply whose captured
    /// value is no longer current is dropped, so a read still in flight when the tunnel
    /// goes down can't repopulate the list `clearRoutes()` just emptied — which would leave
    /// the selector enabled over dead nodes, and a tap on one stuck showing a selection the
    /// core never applied (with no session, the select never reports back to reconcile it).
    /// Main-thread only, matching every caller.
    private var routeReadGeneration = 0


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

    // Exit nodes (0.0.0.0/0 or ::/0 routes) get their own dedicated selector instead of
    // appearing in the standard resources list.
    var resourceRouteInfo: [RoutesSelectionInfo] {
        routeInfo.filter { !$0.isExitNode }
    }

    var filteredResourceRoutes: [RoutesSelectionInfo] {
        filteredRoutes.filter { !$0.isExitNode }
    }

    var exitNodes: [RoutesSelectionInfo] {
        routeInfo.filter { $0.isExitNode }
    }

    var selectedExitNode: RoutesSelectionInfo? {
        exitNodes.first { $0.selected }
    }
    
    /// Applies a choice made in the single-selection exit node UI. Passing `nil` is the
    /// "None" entry: it clears the active exit node so traffic falls back to the default
    /// path. Selecting a node is delegated to `selectRoute`, which handles the mutual
    /// exclusion between exit nodes.
    func setExitNode(_ exitNode: RoutesSelectionInfo?) {
        // `selected` is a plain property on a reference type stored in a @Published array,
        // so mutating it publishes nothing on its own. Announce the change by hand or the
        // selector keeps showing the old value until the getRoutes round-trip lands.
        guard let exitNode else {
            guard let current = selectedExitNode else { return }
            objectWillChange.send()
            current.objectWillChange.send()
            current.selected = false
            exitNodeGeneration &+= 1
            let generation = exitNodeGeneration
            // Reconcile afterwards for the same reason sendSelectAndReconcile does: the
            // extension always replies "true", so only a fresh GetRoutes proves the core
            // actually dropped the node. Hop to main before touching the generation and
            // @Published state: this completion runs on whatever queue the extension
            // replies on.
            networkExtensionAdapter.deselectRoutes(id: current.name) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.exitNodeGeneration == generation else { return }
                    self.getRoutes()
                }
            }
            return
        }

        guard !exitNode.selected else { return }
        objectWillChange.send()
        selectRoute(route: exitNode)
    }

    /// Drops every cached route. Called when the tunnel goes down: the network map is only
    /// readable through the extension, so keeping stale entries would leave the exit node
    /// selector offering nodes that can no longer be applied.
    func clearRoutes() {
        // Bump before the empty check, not after it: a read started while the tunnel was up
        // can still be in flight with nothing cached yet, and letting the early return skip
        // the invalidation would let that reply refill the list after the tunnel is gone.
        routeReadGeneration &+= 1
        guard !routeInfo.isEmpty else { return }
        routeInfo = []
    }

    func toggleSelected(for routeId: UUID) {
            if let index = routeInfo.firstIndex(where: { $0.id == routeId }) {
                routeInfo[index].selected.toggle()
            }
        }

    func getRoutes() {
        routeReadGeneration &+= 1
        let generation = routeReadGeneration
        // Hop to main before touching the generation and @Published state: this completion
        // runs on whatever queue the extension replies on.
        networkExtensionAdapter.getRoutes { [weak self] details in
            DispatchQueue.main.async {
                guard let self, self.routeReadGeneration == generation else { return }
                self.routeInfo = details.routeSelectionInfo
                print("Route count: \(details.routeSelectionInfo.count)")
            }
        }
    }
    
    func selectRoute(route: RoutesSelectionInfo) {
        guard let index = self.routeInfo.firstIndex(where: { $0.id == route.id }) else { return }

        // `selected` is not @Published (kept for Codable); notify observers explicitly.
        self.routeInfo[index].objectWillChange.send()
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
        //
        // Tagging the operation guards the other half of that race: a second choice made
        // while these round-trips are still in flight supersedes this one, and the check
        // in the notify below keeps this stale select from landing after it.
        exitNodeGeneration &+= 1
        let generation = exitNodeGeneration

        let siblings = routeInfo.filter { $0.id != route.id && $0.selected && $0.isExitNode }
        guard !siblings.isEmpty else {
            sendSelectAndReconcile(route: route)
            return
        }

        let group = DispatchGroup()
        for sibling in siblings {
            // `selected` is a plain property on the ObservableObject (kept non-@Published so
            // the class stays trivially Codable), so mutating it emits nothing on its own.
            // Notify the observing RouteCard explicitly so the sibling's toggle flips off now
            // instead of only after the getRoutes reconcile round-trip.
            sibling.objectWillChange.send()
            sibling.selected = false
            group.enter()
            networkExtensionAdapter.deselectRoutes(id: sibling.name) { _ in
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self, self.exitNodeGeneration == generation else { return }
            self.sendSelectAndReconcile(route: route)
        }
    }

    // Sends the select for `route`, then reconciles the optimistic UI selection with the
    // core's real state. Select/Deselect messages don't report the applied result (the
    // extension swallows errors and always replies "true"), so re-read the truth via
    // GetRoutes: if the core rejected the change the toggle reverts instead of leaving a
    // stale optimistic selection in place.
    private func sendSelectAndReconcile(route: RoutesSelectionInfo) {
        networkExtensionAdapter.selectRoutes(id: route.name) { [weak self] _ in
            DispatchQueue.main.async {
                self?.getRoutes()
            }
        }
    }
    
    func selectAllRoutes() {
        networkExtensionAdapter.selectRoutes(id: "All") { details in
            print("selected all routes")
        }
    }
    
    func deselectRoute(route: RoutesSelectionInfo) {
        guard let index = self.routeInfo.firstIndex(where: { $0.id == route.id }) else { return }
        self.routeInfo[index].objectWillChange.send()
        self.routeInfo[index].selected = false
        // Reconcile with the core's real state, mirroring selectRoute.
        networkExtensionAdapter.deselectRoutes(id: route.name) { [weak self] _ in
            DispatchQueue.main.async {
                self?.getRoutes()
            }
        }
    }
    
    func deselectAllRoutes() {
        networkExtensionAdapter.deselectRoutes(id: "All") { details in
            print("deselect all routes")
        }
    }
    
}
