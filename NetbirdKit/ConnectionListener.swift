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

    func onDisconnected() {
        let wasRestarting = adapter.isRestarting
        adapter.isRestarting = false
        adapter.clientState = .disconnected
        AppLogger.shared.log("onDisconnected: state=disconnected, wasRestarting=\(wasRestarting)")
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
