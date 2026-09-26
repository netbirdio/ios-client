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

    var adapter: NetBirdAdapter

    init(adapter: NetBirdAdapter, onConnectionChanged: ((ClientState) -> Void)? = nil, completionHandler: @escaping (Error?) -> Void) {
        self.completionHandler = completionHandler
        self.adapter = adapter
        self.onConnectionChanged = onConnectionChanged
    }

    func onAddressChanged(_ p0: String?, p1: String?) {
        // do nothing
    }

    func onConnected() {
        onConnectionChanged?(.connected)
        let wasRestarting = adapter.isRestarting
        adapter.isRestarting = false
        adapter.clientState = .connected
        AppLogger.shared.log("onConnected: state=connected, wasRestarting=\(wasRestarting)")

        DispatchQueue.main.async {
            self.completionHandler(nil)
        }
    }

    func onConnecting() {
        onConnectionChanged?(.connecting)
        if adapter.isRestarting {
            AppLogger.shared.log("onConnecting: suppressed (isRestarting=true)")
        } else {
            adapter.clientState = .connecting
            AppLogger.shared.log("onConnecting: state=connecting")
        }
    }

    func onDisconnected() {
        // The core uses Connecting/NoNetwork for recoverable outages. Disconnected
        // means Run has stopped; pretending it is still retrying leaves a dead tunnel.
        onConnectionChanged?(.disconnected)
        let wasRestarting = adapter.isRestarting
        adapter.isRestarting = false
        adapter.clientState = .disconnected
        AppLogger.shared.log("onDisconnected: state=disconnected, wasRestarting=\(wasRestarting)")
        if !wasRestarting && adapter.needsLoginCached() {
            AppLogger.shared.log("onDisconnected: login required — signalling teardown")
            adapter.onLoginRequired?()
        }
        adapter.notifyStopCompleted()
    }

    func onDisconnecting() {
        onConnectionChanged?(.disconnecting)
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
