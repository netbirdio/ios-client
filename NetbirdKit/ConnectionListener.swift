//
//  ConnectionListener.swift
//  NetBird
//
//  Created by Pascal Fischer on 09.11.23.
//

import Foundation
import NetBirdSDK

class ConnectionListener: NSObject, NetBirdSDKConnectionListenerProtocol {

    var completionHandler: (Error?) -> Void

    private let onConnectionChanged: ((ClientState) -> Void)?

    private let startLock = NSLock()
    private var hasStarted = false

    var adapter: NetBirdAdapter

    init(adapter: NetBirdAdapter, onConnectionChanged: ((ClientState) -> Void)? = nil, completionHandler: @escaping (Error?) -> Void) {
        self.completionHandler = completionHandler
        self.adapter = adapter
        self.onConnectionChanged = onConnectionChanged
    }

    func onAddressChanged(_ p0: String?, p1: String?) {
        // do nothing
    }

    func onStateChanged(_ state: Int) {
        guard let state = ClientState(sdkState: state) else { return }
        // ClientStart can be reported as NoNetwork when startup is offline.
        if state == .connecting || state == .noNetwork {
            onConnecting()
        }
        if state == .disconnected && !engineHasStarted { return }
        onConnectionChanged?(state)
        if adapter.isRestarting && (state == .connecting || state == .disconnecting) {
            AppLogger.shared.log("onStateChanged: suppressed state=\(state) (isRestarting=true)")
            return
        }
        adapter.clientState = state
        AppLogger.shared.log("onStateChanged: state=\(state)")
    }

    func onConnected() {
        DispatchQueue.main.async {
            self.completionHandler(nil)
        }
    }

    func onConnecting() {
        startLock.lock()
        hasStarted = true
        startLock.unlock()
    }

    private var engineHasStarted: Bool {
        startLock.lock()
        defer { startLock.unlock() }
        return hasStarted
    }

    func onDisconnected() {
        // Registering a listener synchronously replays the reused client's previous
        // disconnected state and auth error. Only the new run may request teardown.
        guard engineHasStarted else { return }
        // Disconnected means Run has stopped; NoNetwork is recoverable.
        if !adapter.isRestarting && adapter.needsLoginCached() {
            AppLogger.shared.log("onDisconnected: login required — signalling teardown")
            adapter.onLoginRequired?()
        }
    }

    func onDisconnecting() {}

    /// Receives peer-count changes and forwards them to the app as a "network map
    /// changed" signal.
    ///
    /// The core fires this at the end of every network map update — after the route
    /// manager has applied the routes, see Engine.updateNetworkMap — and whenever a
    /// route gains or loses its routing peer or a peer's connection state flips. That
    /// makes it the one callback saying the list GetRoutes answers with has moved.
    /// `onConnected` is too early for that: it fires once management and signal are up,
    /// before the engine is even reachable and well before the first network map.
    /// Android's HomeFragment relies on the same event for the same reason.
    ///
    /// The count itself is unused; peer details come through the status endpoint. The
    /// app cannot be called from here — it is another process — so the change is
    /// announced through the Darwin notify center, the way the app announces MDM policy
    /// changes to this extension. Runs on a Go-spawned thread; posting is thread-safe.
    func onPeersListChanged(_ p0: Int) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(GlobalConstants.darwinNotificationNetworkMapChanged as CFString),
            nil,
            nil,
            true
        )
    }

}
