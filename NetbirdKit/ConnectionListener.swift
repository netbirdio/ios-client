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
        adapter.clientState = .connected
        self.completionHandler(nil)
    }
    
    func onConnecting() {
        adapter.clientState = .connecting
    }
    
    func onDisconnected() {
        adapter.clientState = .disconnected
    }
    
    func onDisconnecting() {
        adapter.clientState = .disconnecting
    }
    
    func onPeersListChanged(_ p0: Int) {
        // do nothing
    }

}
