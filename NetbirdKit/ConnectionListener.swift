//
//  ConnectionListener.swift
//  NetBird
//
//  Created by Pascal Fischer on 09.11.23.
//

import Foundation
import Network
import NetBirdSDK

class ConnectionListener: NSObject, NetBirdSDKConnectionListenerProtocol {

    var completionHandler: (Error?) -> Void

    var adapter: NetBirdAdapter

    init(adapter: NetBirdAdapter, completionHandler: @escaping (Error?) -> Void) {
        self.completionHandler = completionHandler
        self.adapter = adapter
    }

    func onAddressChanged(_ p0: String?, p1: String?) {
        // do nothing
    }

    func onConnected() {
        let wasRestarting = adapter.isRestarting
        adapter.isRestarting = false
        adapter.clientState = .connected
        AppLogger.shared.log("onConnected: state=connected, wasRestarting=\(wasRestarting)")

        DispatchQueue.main.async {
            self.completionHandler(nil)
        }
    }

    func onConnecting() {
        if adapter.isRestarting {
            AppLogger.shared.log("onConnecting: suppressed (isRestarting=true)")
        } else {
            adapter.clientState = .connecting
            AppLogger.shared.log("onConnecting: state=connecting")
        }
    }

    /// Check if network is currently available using synchronous path check
    private func isNetworkAvailable() -> Bool {
        let monitor = NWPathMonitor()
        let semaphore = DispatchSemaphore(value: 0)
        var isAvailable = false

        monitor.pathUpdateHandler = { path in
            isAvailable = path.status == .satisfied
            semaphore.signal()
        }

        let queue = DispatchQueue(label: "NetworkCheck")
        monitor.start(queue: queue)

        // Wait up to 100ms for network status
        _ = semaphore.wait(timeout: .now() + 0.1)
        monitor.cancel()

        return isAvailable
    }

    func onDisconnected() {
        let wasRestarting = adapter.isRestarting
        let isNetworkUnavailableFlag = adapter.isNetworkUnavailable
        adapter.isRestarting = false

        // Check both the flag AND actual network status
        // This handles race condition where Go SDK fires onDisconnected before our handler sets the flag
        let networkAvailable = isNetworkAvailable()
        let shouldStayConnecting = isNetworkUnavailableFlag || !networkAvailable

        // When network is unavailable, keep the tunnel alive by staying in "connecting" state
        // instead of "disconnected". This allows automatic reconnection when network returns.
        if shouldStayConnecting {
            adapter.clientState = .connecting
            AppLogger.shared.log("onDisconnected: network unavailable (flag=\(isNetworkUnavailableFlag), networkAvailable=\(networkAvailable)) - staying in connecting state for auto-reconnect, wasRestarting=\(wasRestarting)")
        } else {
            adapter.clientState = .disconnected
            AppLogger.shared.log("onDisconnected: state=disconnected, wasRestarting=\(wasRestarting)")
        }
        adapter.notifyStopCompleted()
    }

    func onDisconnecting() {
        if adapter.isRestarting {
            AppLogger.shared.log("onDisconnecting: suppressed (isRestarting=true)")
        } else {
            adapter.clientState = .disconnecting
            AppLogger.shared.log("onDisconnecting: state=disconnecting")
        }
    }
    
    func onPeersListChanged(_ p0: Int) {
        // do nothing
    }

}
