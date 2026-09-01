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
        let isNetworkUnavailableFlag = adapter.isNetworkUnavailable

        // Session expiry takes priority over the keep-alive-on-network-loss logic below.
        // If the last management error was an auth failure there is nothing to reconnect
        // to, so we must NOT linger in .connecting — that keeps the now-dead tunnel
        // interface up with the VPN's default route and black-holes ALL traffic until the
        // user manually intervenes (independent of On-Demand). Mark disconnected and let
        // the provider tear the tunnel down so traffic returns to the physical interface.
        // Uses the network-free cached check — safe to call during teardown.
        if !wasRestarting && adapter.needsLoginCached() {
            adapter.clientState = .disconnected
            AppLogger.shared.log("onDisconnected: login required — signalling teardown")
            adapter.onLoginRequired?()
            adapter.notifyStopCompleted()
            return
        }

        // When network is unavailable, keep the tunnel alive by staying in "connecting" state
        // instead of "disconnected". This allows automatic reconnection when network returns.
        // PacketTunnelProvider owns the long-lived NWPathMonitor and publishes its result
        // through this flag. Creating another monitor here and waiting only 100 ms often
        // timed out before its first update, falsely reporting an available path as down.
        if isNetworkUnavailableFlag {
            adapter.clientState = .connecting
            AppLogger.shared.log("onDisconnected: network unavailable - staying in connecting state for auto-reconnect, wasRestarting=\(wasRestarting)")
        } else {
            adapter.clientState = .disconnected
            AppLogger.shared.log("onDisconnected: state=disconnected, wasRestarting=\(wasRestarting)")

            // If session expired (not a network drop), signal login required so the user
            // gets a notification. Uses the network-free cached check: the blocking
            // needsLogin() variant is a full Login RPC (retried with backoff for up to two
            // minutes) on every ordinary disconnect, and it reports the same auth state the
            // recorder already holds — the engine marks it from the management error before
            // firing this callback.
            if !wasRestarting && adapter.needsLoginCached() {
                AppLogger.shared.log("onDisconnected: login required detected — signalling")
                adapter.onLoginRequired?()
            }
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
