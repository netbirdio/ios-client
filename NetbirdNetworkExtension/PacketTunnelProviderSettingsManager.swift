//
//  PacketTunnelProviderSettingsManager.swift
//  NetBirdiOS
//
//  Created by Pascal Fischer on 06.10.23.
//

import Foundation
import NetworkExtension

class PacketTunnelProviderSettingsManager {
    
    private weak var packetTunnelProvider: PacketTunnelProvider?
    
    private var interfaceIP: String?
    private var interfaceIPv6: String?
    private var ipv4Routes: [NEIPv4Route]?
    private var ipv6Routes: [NEIPv6Route]?
    private var dnsSettings: NEDNSSettings?
    private var needFallbackNS: Bool = false
    private var containsDefaultRoute: Bool = false

    /// Guards every stored input above and the apply state below. The inputs arrive on the
    /// network change listener's and the DNS manager's queues, `setTunnelNetworkSettings`
    /// completes on a queue of the OS's choosing, and nothing else orders them.
    private let stateLock = NSLock()

    /// True from handing settings to the OS until its completion runs. Only one
    /// `setTunnelNetworkSettings` call is ever in flight.
    private var isApplying = false
    /// Fingerprint of the settings in flight, valid while `isApplying`.
    private var inFlightFingerprint: String?
    /// Fingerprint of the settings the OS last accepted; nil after a failed apply, so the
    /// next change is applied whatever it is.
    private var lastAppliedFingerprint: String?
    /// The newest settings that changed while an apply was in flight, applied once it
    /// completes. Replaced, not queued: only the latest state matters.
    private var pendingApply: (settings: NEPacketTunnelNetworkSettings, fingerprint: String)?
    /// Updates absorbed by the current in-flight apply, for the log line.
    private var coalescedUpdates = 0

    // Link-local dummy IPv6 used to satisfy NEIPv6Settings when the
    // interface has no IPv6 address but we still need a ::/0 blackhole route
    // to prevent IPv6 leaks while the IPv4 default route is in the tunnel.
    private static let ipv6BlackholeAddress = "fe80::1"
    private static let ipv6BlackholePrefix: NSNumber = 64

    init(with packetTunnelProvider: PacketTunnelProvider) {
        self.packetTunnelProvider = packetTunnelProvider
    }

    func setRoutes(v4Routes: [NEIPv4Route], v6Routes: [NEIPv6Route], containsDefault: Bool) {
        stateLock.lock()
        needFallbackNS = containsDefault
        containsDefaultRoute = containsDefault
        ipv4Routes = v4Routes
        ipv6Routes = v6Routes
        stateLock.unlock()
        updateTunnel()
    }

    func setDNS(config: HostDNSConfig) {
        let dnsSettings = NEDNSSettings(servers: [config.serverIP])

        // Always route all DNS through the tunnel on iOS.
        // The Go DNS server has a root zone fallback handler that forwards
        // unmatched queries to host DNS servers (e.g. 1.1.1.1).
        // This avoids DNS failures when exit node routes (0.0.0.0/0) are
        // added or removed, as iOS system DNS on cellular is unreliable
        // with an active VPN tunnel.
        dnsSettings.matchDomains = [""]

        var searchDomains: [String] = []
        for domain in config.domains {
            if !domain.disabled && !domain.matchOnly {
                searchDomains.append(domain.domain)
            }
        }
        if !searchDomains.isEmpty {
            dnsSettings.searchDomains = searchDomains
        }

        stateLock.lock()
        self.dnsSettings = dnsSettings
        stateLock.unlock()
        updateTunnel()
    }
    
    func setInterfaceIP(interfaceIP: String) {
        stateLock.lock()
        defer { stateLock.unlock() }
        self.interfaceIP = interfaceIP
        // A new engine session always pushes setInterfaceIP first, then setInterfaceIPv6
        // only when the session actually has a v6 address. Drop any previous session's v6
        // here so a v4-only session (IPv6 disabled or a v4-only profile) can't keep applying
        // a stale interfaceIPv6 — which would send createTunnelSettings down the dual-stack
        // branch and skip the ::/0 blackhole, leaking IPv6 past a selected exit node. This
        // manager outlives individual engine sessions (it is owned by the extension process),
        // so the reset has to happen at the session boundary rather than on teardown.
        self.interfaceIPv6 = nil
    }

    func setInterfaceIPv6(interfaceIPv6: String) {
        stateLock.lock()
        defer { stateLock.unlock() }
        self.interfaceIPv6 = interfaceIPv6
    }

    func getInterfaceIP() -> String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return self.interfaceIP
    }
    
    /// Pushes the current inputs to the OS, coalescing and de-duplicating the calls.
    ///
    /// `setTunnelNetworkSettings` is the only way to change the tunnel's routes on iOS. It
    /// takes a few hundred milliseconds, is serialised by the OS, and flaps the utun every
    /// time. The core announces its prefix set after every single route it adds — a connect
    /// with a dozen static routes produced a dozen back-to-back applies, one per prefix,
    /// keeping the tunnel in reconfiguration for seconds — and it re-announces an unchanged
    /// set at every engine restart, as the DNS manager re-announces an unchanged DNS config.
    /// Android answers the same notification by pulling the latest state onto a serial
    /// thread and diffing it against what the TUN was last built with; this is that
    /// pattern: at most one apply in flight, the newest settings waiting behind it replace
    /// any older waiting ones, and settings identical to what is — or is about to be — in
    /// effect are dropped.
    private func updateTunnel() {
        stateLock.lock()
        guard let settings = createTunnelSettingsLocked() else {
            stateLock.unlock()
            AppLogger.shared.log("Tunnel settings: no interface address yet, nothing to apply")
            return
        }
        let fingerprint = settingsFingerprintLocked()
        // What the OS holds once the current apply, if any, has completed.
        let effective = isApplying ? inFlightFingerprint : lastAppliedFingerprint
        if fingerprint == effective {
            // Covers a queued older change too: the newest desired state is the effective one.
            pendingApply = nil
            stateLock.unlock()
            return
        }
        if isApplying {
            pendingApply = (settings, fingerprint)
            coalescedUpdates += 1
            stateLock.unlock()
            return
        }
        isApplying = true
        inFlightFingerprint = fingerprint
        stateLock.unlock()
        applyTunnelSettings(settings, fingerprint: fingerprint)
    }

    /// Hands `settings` to the OS and, once it completes, applies whatever change queued up
    /// behind it. Called without the lock held and only while `isApplying` is set by the
    /// caller, so no second apply can start underneath it.
    private func applyTunnelSettings(_ settings: NEPacketTunnelNetworkSettings, fingerprint: String) {
        guard let provider = packetTunnelProvider else {
            stateLock.lock()
            isApplying = false
            inFlightFingerprint = nil
            pendingApply = nil
            stateLock.unlock()
            AppLogger.shared.log("Tunnel settings: provider is gone, dropping the update")
            return
        }

        let v4Count = settings.ipv4Settings?.includedRoutes?.count ?? 0
        let v6Count = settings.ipv6Settings?.includedRoutes?.count ?? 0
        provider.setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else { return }
            self.stateLock.lock()
            // A failed apply leaves the OS in an unknown state; forget what was in effect so
            // the next change is applied rather than skipped as a repeat.
            self.lastAppliedFingerprint = error == nil ? fingerprint : nil
            let coalesced = self.coalescedUpdates
            self.coalescedUpdates = 0
            let next = self.pendingApply
            self.pendingApply = nil
            if let next {
                self.inFlightFingerprint = next.fingerprint
            } else {
                self.isApplying = false
                self.inFlightFingerprint = nil
            }
            self.stateLock.unlock()

            if let error {
                AppLogger.shared.log("Error assigning routes: \(error.localizedDescription)")
            } else {
                AppLogger.shared.log("Routes set successfully (v4: \(v4Count), v6: \(v6Count), coalesced: \(coalesced))")
            }
            if let next {
                self.applyTunnelSettings(next.settings, fingerprint: next.fingerprint)
            }
        }
    }

    /// Identifies the settings `createTunnelSettingsLocked` builds from the current inputs,
    /// so two applies that would configure the tunnel identically can be told apart from a
    /// real change. Route order is irrelevant to the OS, so the lists are sorted. A nil v4
    /// route list is not an empty one: nil falls back to the interface route. Caller holds
    /// `stateLock`.
    private func settingsFingerprintLocked() -> String {
        let v4 = ipv4Routes.map { routes in
            routes.map { "\($0.destinationAddress)/\($0.destinationSubnetMask)" }.sorted().joined(separator: ",")
        } ?? "nil"
        let v6 = (ipv6Routes ?? []).map { "\($0.destinationAddress)/\($0.destinationNetworkPrefixLength)" }.sorted().joined(separator: ",")
        var dns = ""
        if let dnsSettings {
            dns = dnsSettings.servers.joined(separator: ",")
                + "|" + (dnsSettings.searchDomains ?? []).joined(separator: ",")
                + "|" + (dnsSettings.matchDomains ?? []).joined(separator: ",")
        }
        return [
            "ip4=\(interfaceIP ?? "")",
            "ip6=\(interfaceIPv6 ?? "")",
            "default=\(containsDefaultRoute)",
            "v4=\(v4)",
            "v6=\(v6)",
            "dns=\(dns)",
        ].joined(separator: ";")
    }

    /// Builds the settings from the current inputs. Caller holds `stateLock`.
    private func createTunnelSettingsLocked() -> NEPacketTunnelNetworkSettings? {
        if let interfaceIP = interfaceIP {
            if let (ipAddress, subnetMask) = extractIPAddressAndSubnet(from: interfaceIP) {
                let tunnelNetworkSettings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: ipAddress)
                let ipv4Settings = NEIPv4Settings(addresses: [ipAddress], subnetMasks: [subnetMask])
                
                ipv4Settings.includedRoutes = [ NEIPv4Route(destinationAddress: ipAddress, subnetMask: subnetMask) ]
                
                if self.ipv4Routes != nil {
                    ipv4Settings.includedRoutes = self.ipv4Routes
                }
                tunnelNetworkSettings.ipv4Settings = ipv4Settings
                
                var v6Addresses: [String] = []
                var v6PrefixLengths: [NSNumber] = []
                var v6Routes: [NEIPv6Route] = []

                if let ipv6CIDR = self.interfaceIPv6,
                   let (v6Addr, v6Prefix) = extractIPv6AddressAndPrefix(from: ipv6CIDR) {
                    v6Addresses.append(v6Addr)
                    v6PrefixLengths.append(NSNumber(value: v6Prefix))
                    v6Routes = self.ipv6Routes ?? []
                } else if self.containsDefaultRoute {
                    v6Addresses.append(Self.ipv6BlackholeAddress)
                    v6PrefixLengths.append(Self.ipv6BlackholePrefix)
                    v6Routes = [NEIPv6Route(destinationAddress: "::", networkPrefixLength: 0)]
                }

                if !v6Addresses.isEmpty {
                    let ipv6Settings = NEIPv6Settings(addresses: v6Addresses, networkPrefixLengths: v6PrefixLengths)
                    if !v6Routes.isEmpty {
                        ipv6Settings.includedRoutes = v6Routes
                    }
                    tunnelNetworkSettings.ipv6Settings = ipv6Settings
                } else {
                    // Always assign IPv6 settings explicitly: leaving the property nil
                    // makes setTunnelNetworkSettings KEEP the previously applied IPv6
                    // config, so the ::/0 blackhole installed while an exit node was
                    // selected would linger after deselect and keep black-holing traffic.
                    let ipv6Settings = NEIPv6Settings(addresses: [Self.ipv6BlackholeAddress], networkPrefixLengths: [Self.ipv6BlackholePrefix])
                    // Explicitly clear any previously-applied IPv6 routes.
                    ipv6Settings.includedRoutes = []
                    tunnelNetworkSettings.ipv6Settings = ipv6Settings
                }
                
                tunnelNetworkSettings.mtu = 1280
                
                if self.dnsSettings != nil {
                    tunnelNetworkSettings.dnsSettings = self.dnsSettings
                }
                
                return tunnelNetworkSettings
            }
        }

        return nil
    }

    private func extractIPv6AddressAndPrefix(from cidr: String) -> (String, Int)? {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2,
              let prefix = Int(parts[1]),
              (0...128).contains(prefix) else {
            return nil
        }
        return (String(parts[0]), prefix)
    }

}
