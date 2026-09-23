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

    /// Bumped by every route read, by `clearRoutes()` and by every optimistic selection
    /// write. A GetRoutes reply whose captured value is no longer current is dropped, so a
    /// read still in flight when the tunnel goes down can't repopulate the list
    /// `clearRoutes()` just emptied — which would leave the selector enabled over dead
    /// nodes, and a tap on one stuck showing a selection the core never applied (with no
    /// session, the select never reports back to reconcile it) — and a read dispatched
    /// before a tap can't answer after it with the pre-tap selection. Main-thread only,
    /// matching every caller.
    private var routeReadGeneration = 0

    /// A network map refresh waiting to run (see `scheduleNetworkMapRefresh`). One
    /// scheduled read absorbs every change notification that arrives before it fires; a
    /// change landing after the fire schedules the next one. Main-thread only.
    private var pendingNetworkMapRefresh: DispatchWorkItem?

    /// Advanced by `clearRoutes()` and `beginSelectionMutation()`, captured when a change
    /// notification arrives and re-checked once its refresh request reaches the main queue.
    /// That hop is a window: a notification in transit while the routes were cleared or a
    /// selection written would otherwise schedule a read after the very invalidation that
    /// should have dropped it — and after `clearRoutes()`, with the extension still winding
    /// down, such a read can repopulate a list nothing clears again. Lock-guarded because
    /// the capture happens on whatever thread the Darwin notify center delivers on.
    private var networkMapEpoch = 0
    private let networkMapEpochLock = NSLock()

    /// How long a notified change waits before it is read back. The core announces a
    /// change per peer and per route, so a connect with dozens of peers produces dozens
    /// of notifications within a few seconds, and each read is an IPC round-trip that
    /// serialises the whole route list — so reads are coalesced to at most one per window.
    /// Short enough that the exit node selector still fills in well under a second after
    /// the first network map.
    private static let networkMapRefreshDelay: TimeInterval = 0.3


    init(networkExtensionAdapter: NetworkExtensionAdapter) {
        self.networkExtensionAdapter = networkExtensionAdapter
        self.routeInfo = []
        self.selectionFilter = "All"
        self.routeFilter = ""
        self.tappedRoute = nil        
        self.selectedRouteId = nil
        startObservingNetworkMapChanges()
    }

    /// Unregisters before this object can go away: the Darwin observer holds an
    /// unretained pointer to it.
    deinit {
        stopObservingNetworkMapChanges()
        pendingNetworkMapRefresh?.cancel()
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
            let revertPoint = beginSelectionMutation()
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
            networkExtensionAdapter.deselectRoutes(id: current.name) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self, self.exitNodeGeneration == generation else { return }
                    switch result {
                    case .success:
                        self.getRoutes()
                    case .failure(let error):
                        // The request never reached the core, so the node is still in
                        // force. Put the selector back rather than leaving it showing a
                        // "None" the core never applied.
                        print("Deselecting exit node failed: \(error.localizedDescription)")
                        self.revert(to: revertPoint)
                    }
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
        // A refresh the extension announced while winding down has nothing left to read,
        // whether it is already scheduled or still on its way to the main queue.
        pendingNetworkMapRefresh?.cancel()
        pendingNetworkMapRefresh = nil
        advanceNetworkMapEpoch()
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
        networkExtensionAdapter.getRoutes { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.routeReadGeneration == generation else { return }
                switch result {
                case .success(let details):
                    self.routeInfo = details.routeSelectionInfo
                    print("Route count: \(details.routeSelectionInfo.count)")
                case .failure(let error):
                    // A request that never reached the core says nothing about the network
                    // map, so the cached list stands. Only an answer from the core — an
                    // empty one included — is allowed to replace it. Views may therefore
                    // call this unconditionally: with no tunnel session the read fails and
                    // leaves valid routes alone, and `clearRoutes()` remains the one path
                    // that empties them on a real disconnect.
                    print("Failed to read routes, keeping the cached list: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Listens for the extension announcing that the core's network map moved (see
    /// `GlobalConstants.darwinNotificationNetworkMapChanged`). The routes only exist in
    /// the extension process, and the read `applyStatusSideEffects` makes on `.connected`
    /// lands before the first network map has arrived, so without this signal the list
    /// stayed empty until some view's onAppear happened to read it again.
    private func startObservingNetworkMapChanges() {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                Unmanaged<RoutesViewModel>.fromOpaque(observer).takeUnretainedValue().scheduleNetworkMapRefresh()
            },
            GlobalConstants.darwinNotificationNetworkMapChanged as CFString,
            nil,
            .deliverImmediately
        )
    }

    private func stopObservingNetworkMapChanges() {
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(GlobalConstants.darwinNotificationNetworkMapChanged as CFString),
            nil
        )
    }

    /// Reads the network map back after a change notification, coalescing bursts into one
    /// read per `networkMapRefreshDelay`.
    ///
    /// Safe to call from any thread; the state lives on main. Nothing is lost to the
    /// coalescing: the extension posts after the core has applied a change, and the read
    /// happens when the work item fires, so a change announced while a refresh is pending
    /// is covered by that refresh, and one announced after it fired — the item clears
    /// itself before reading — schedules the next. A notification overtaken on its way to
    /// main by `clearRoutes()` or a selection write is dropped, see `networkMapEpoch`.
    func scheduleNetworkMapRefresh() {
        let epoch = currentNetworkMapEpoch()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.currentNetworkMapEpoch() == epoch, self.pendingNetworkMapRefresh == nil else { return }
            let refresh = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingNetworkMapRefresh = nil
                self.getRoutes()
            }
            self.pendingNetworkMapRefresh = refresh
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.networkMapRefreshDelay, execute: refresh)
        }
    }

    private func currentNetworkMapEpoch() -> Int {
        networkMapEpochLock.lock()
        defer { networkMapEpochLock.unlock() }
        return networkMapEpoch
    }

    /// Drops every change notification still on its way to the main queue.
    private func advanceNetworkMapEpoch() {
        networkMapEpochLock.lock()
        networkMapEpoch &+= 1
        networkMapEpochLock.unlock()
    }

    /// The selection state before an optimistic mutation, tagged with the mutation that
    /// took it, so a round-trip the user has already superseded reverts nothing.
    private struct SelectionRevertPoint {
        let generation: Int
        let selection: [UUID: Bool]
    }

    /// Bumped by every optimistic selection change. `revert(to:)` compares against it, so a
    /// failure arriving after the user has moved on is dropped instead of undoing the newer
    /// choice. Main-thread only, matching every caller.
    private var selectionGeneration = 0

    /// Records a revert point covering every cached route and claims the next generation.
    /// Call immediately before writing an optimistic selection.
    private func beginSelectionMutation() -> SelectionRevertPoint {
        selectionGeneration &+= 1
        // Retire every read still in flight, and the coalesced refresh waiting to start, as
        // well. Either could answer after this write with the selection the core held
        // before it and overwrite the optimistic state; the reconcile read the mutation
        // issues afterwards is the one allowed to answer, and the mutation's own effects
        // in the core announce themselves, so a refresh follows anyway. Reads are frequent
        // now that the extension announces every network map change, so that window is no
        // longer negligible.
        routeReadGeneration &+= 1
        pendingNetworkMapRefresh?.cancel()
        pendingNetworkMapRefresh = nil
        advanceNetworkMapEpoch()
        return SelectionRevertPoint(
            generation: selectionGeneration,
            selection: Dictionary(routeInfo.map { ($0.id, $0.selected) }, uniquingKeysWith: { first, _ in first })
        )
    }

    /// Undoes the optimistic writes covered by `point`, skipping routes that are no longer
    /// cached. `selected` is a plain property on a reference type held in a @Published
    /// array, so every restored route has to announce its own change.
    private func revert(to point: SelectionRevertPoint) {
        guard selectionGeneration == point.generation else { return }
        var changed = false
        for route in routeInfo {
            guard let wasSelected = point.selection[route.id], route.selected != wasSelected else { continue }
            route.objectWillChange.send()
            route.selected = wasSelected
            changed = true
        }
        if changed { objectWillChange.send() }
    }
    
    func selectRoute(route: RoutesSelectionInfo) {
        guard let index = self.routeInfo.firstIndex(where: { $0.id == route.id }) else { return }

        // Taken before the optimistic writes below so a rejected round-trip can undo all of
        // them — this route's selection and, for an exit node, its siblings' deselection.
        let revertPoint = beginSelectionMutation()

        // `selected` is not @Published (kept for Codable); notify both observers explicitly.
        self.objectWillChange.send()
        self.routeInfo[index].objectWillChange.send()
        self.routeInfo[index].selected = true

        // Non-exit routes select independently.
        guard route.isExitNode else {
            sendSelectAndReconcile(route: route, revertingTo: revertPoint)
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
            sendSelectAndReconcile(route: route, revertingTo: revertPoint)
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
            // A failed deselect is not fatal here: the select still goes out, and the
            // GetRoutes reconcile below reports whatever the core actually ended up with.
            // When there is no session at all the select fails too, and that failure is
            // what reverts the whole optimistic change.
            networkExtensionAdapter.deselectRoutes(id: sibling.name) { _ in
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self, self.exitNodeGeneration == generation else { return }
            self.sendSelectAndReconcile(route: route, revertingTo: revertPoint)
        }
    }

    /// Sends the select for `route`, then reconciles the optimistic UI selection with the
    /// core's real state.
    ///
    /// Select/Deselect messages don't report the applied result (the extension swallows
    /// errors and always replies "true"), so re-read the truth via GetRoutes: if the core
    /// rejected the change the toggle reverts instead of leaving a stale optimistic
    /// selection in place.
    ///
    /// A select that never reached the core at all — no tunnel session, a send that threw,
    /// an extension that never answered — gets no reconcile to revert it, because GetRoutes
    /// would fail for the same reason and deliberately leaves the cache (optimistic writes
    /// included) untouched. So undo the optimistic writes here instead, from the revert
    /// point taken before them.
    ///
    /// - Parameters:
    ///   - route: the route whose selection was already written optimistically.
    ///   - revertPoint: the selection state to restore if the core never accepted it.
    private func sendSelectAndReconcile(route: RoutesSelectionInfo, revertingTo revertPoint: SelectionRevertPoint) {
        networkExtensionAdapter.selectRoutes(id: route.name) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success:
                    self.getRoutes()
                case .failure(let error):
                    print("Selecting route failed: \(error.localizedDescription)")
                    self.revert(to: revertPoint)
                }
            }
        }
    }
    
    func selectAllRoutes() {
        networkExtensionAdapter.selectRoutes(id: "All") { result in
            switch result {
            case .success: print("selected all routes")
            case .failure(let error): print("Selecting all routes failed: \(error.localizedDescription)")
            }
        }
    }
    
    func deselectRoute(route: RoutesSelectionInfo) {
        guard let index = self.routeInfo.firstIndex(where: { $0.id == route.id }) else { return }
        let revertPoint = beginSelectionMutation()
        self.objectWillChange.send()
        self.routeInfo[index].objectWillChange.send()
        self.routeInfo[index].selected = false
        // Reconcile with the core's real state, mirroring selectRoute — and revert the
        // optimistic write when the request never got there.
        networkExtensionAdapter.deselectRoutes(id: route.name) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success:
                    self.getRoutes()
                case .failure(let error):
                    print("Deselecting route failed: \(error.localizedDescription)")
                    self.revert(to: revertPoint)
                }
            }
        }
    }
    
    func deselectAllRoutes() {
        networkExtensionAdapter.deselectRoutes(id: "All") { result in
            switch result {
            case .success: print("deselect all routes")
            case .failure(let error): print("Deselecting all routes failed: \(error.localizedDescription)")
            }
        }
    }
    
}
