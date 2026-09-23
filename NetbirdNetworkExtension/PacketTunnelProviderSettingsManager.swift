//
//  PacketTunnelProviderSettingsManager.swift
//  NetBirdiOS
//
//  Created by Pascal Fischer on 06.10.23.
//

import Foundation
import NetworkExtension

class PacketTunnelProviderSettingsManager {

    private enum ApplyOutcome {
        case applied
        case failed(Error)
    }

    private weak var packetTunnelProvider: PacketTunnelProvider?
    
    private var interfaceIP: String?
    private var interfaceIPv6: String?
    private var ipv4Routes: [NEIPv4Route]?
    private var ipv6Routes: [NEIPv6Route]?
    private var dnsSettings: NEDNSSettings?
    private var needFallbackNS: Bool = false
    private var containsDefaultRoute: Bool = false

    /// Guards the stored inputs above. They arrive on the network change listener's and the
    /// DNS manager's queues and are read on `applyQueue`; nothing else orders them.
    private let stateLock = NSLock()

    /// Guards `session`. It is also held across the one call that has to be atomic with a
    /// session change, the tunnel teardown a timed-out apply issues: a `reset()` or
    /// `suspend()` racing with it either gets in first, and the teardown is not issued, or
    /// blocks until the old tunnel's teardown has been issued and only then lets the
    /// provider go on to the next tunnel. Never taken with `stateLock` held.
    private let sessionLock = NSLock()

    /// Counts tunnel lifecycles. `reset()` and `suspend()` bump it synchronously, so from the
    /// moment the provider calls them every completion, timeout and queued change of the
    /// previous tunnel is recognisably stale, including those already sitting on
    /// `applyQueue` ahead of the clearing step.
    private var session = 0

    /// Runs every step of the apply state machine: coalescing, handing settings to the OS,
    /// its completion, the timeout and the clearing part of `reset()`. Confining them to one
    /// serial queue means a change that passed its checks issues its OS call before anything
    /// queued after it, so a `reset()` followed by a new tunnel's first apply can never be
    /// overtaken by an older apply's call — and no lock is ever held across the call.
    /// Nothing on this queue blocks, and nothing waits on it, so it cannot deadlock.
    private let applyQueue = DispatchQueue(label: "io.netbird.NetbirdNetworkExtension.tunnelSettingsApply")

    /// Apply state, confined to `applyQueue`. True from handing settings to the OS until its
    /// completion or timeout runs; only one `setTunnelNetworkSettings` call is ever in flight.
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
    /// Fires if the OS never completes the apply in flight.
    private var applyTimeoutItem: DispatchWorkItem?
    /// Set while the tunnel is going away: from `suspend()` at a stop or a failed start, and
    /// after a lost apply, when the OS may still be working on the call it never completed.
    /// No apply starts while set; `reset()` at the next start clears it.
    private var suspended = false

    // Link-local dummy IPv6 used to satisfy NEIPv6Settings when the
    // interface has no IPv6 address but we still need a ::/0 blackhole route
    // to prevent IPv6 leaks while the IPv4 default route is in the tunnel.
    private static let ipv6BlackholeAddress = "fe80::1"
    private static let ipv6BlackholePrefix: NSNumber = 64
    /// A normal apply completes within a second; a completion that has not arrived by now
    /// is treated as lost. Generous on purpose: a false alarm costs the tunnel.
    private static let applyTimeout: TimeInterval = 10

    init(with packetTunnelProvider: PacketTunnelProvider) {
        self.packetTunnelProvider = packetTunnelProvider
    }

    /// Opens a tunnel lifecycle. Called first thing in `startTunnel`: the OS dropped the
    /// previous tunnel's settings together with its utun, but this manager outlives the
    /// tunnel, so a restart in the same extension process that pushes identical settings
    /// would otherwise be skipped as a repeat and come up without routes. Also retires
    /// whatever the previous tunnel left in flight, should its `suspend()` have been missed.
    /// Returns the new session, for `suspend(session:)`.
    @discardableResult
    func reset() -> Int {
        closeSession(suspend: false, ifSession: nil)
    }

    /// Closes the current tunnel lifecycle. Called from `stopTunnel`, before the OS can start
    /// the next tunnel in this process: the apply in flight is retired, so its completion or
    /// timeout cannot reach that tunnel, and nothing the outgoing engine still pushes while
    /// it winds down is applied to a utun that is about to go.
    func suspend() {
        closeSession(suspend: true, ifSession: nil)
    }

    /// Closes the lifecycle `session`, if it is still the current one. For the start-failure
    /// paths, which end the tunnel without a `stopTunnel`. A stop does not wait for the
    /// engine to exit, so the previous tunnel's engine can report its failure after the next
    /// tunnel's `reset()`; matched against the session that start opened, the late report
    /// suspends nothing.
    func suspend(session: Int) {
        closeSession(suspend: true, ifSession: session)
    }

    /// Bumps the session, so everything the old tunnel has queued or in flight is stale from
    /// this instant, then clears the apply state in queue order. Blocks while a timed-out
    /// apply is issuing its teardown, see `sessionLock`.
    @discardableResult
    private func closeSession(suspend: Bool, ifSession expected: Int?) -> Int {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        if let expected, expected != session {
            return session
        }
        session &+= 1
        applyQueue.async { [weak self] in
            guard let self else { return }
            self.clearApplyState()
            self.suspended = suspend
        }
        return session
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
    
    private var currentSession: Int {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return session
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
    /// effect are dropped. The session is read here, on the caller's thread, so a change
    /// the previous tunnel's engine produced is still recognisable once it runs.
    private func updateTunnel() {
        let session = currentSession
        applyQueue.async { [weak self] in
            self?.applyLatest(session: session)
        }
    }

    /// On `applyQueue`.
    private func applyLatest(session: Int) {
        guard session == currentSession else {
            AppLogger.shared.log("Tunnel settings: dropping a change from a previous tunnel")
            return
        }
        if suspended {
            AppLogger.shared.log("Tunnel settings: dropping a change, the tunnel is going away")
            return
        }
        stateLock.lock()
        let settings = createTunnelSettingsLocked()
        let fingerprint = settingsFingerprintLocked()
        stateLock.unlock()
        guard let settings else {
            AppLogger.shared.log("Tunnel settings: no interface address yet, nothing to apply")
            return
        }
        // What the OS holds once the current apply, if any, has completed.
        let effective = isApplying ? inFlightFingerprint : lastAppliedFingerprint
        if fingerprint == effective {
            // Covers a queued older change too: the newest desired state is the effective one.
            pendingApply = nil
            return
        }
        if isApplying {
            pendingApply = (settings, fingerprint)
            coalescedUpdates += 1
            return
        }
        startApply(settings, fingerprint: fingerprint, session: session)
    }

    /// On `applyQueue`, with no apply in flight. Hands `settings` to the OS and arms the
    /// timeout; the completion hops back onto `applyQueue`, so it never runs concurrently
    /// with the timeout or with a `reset()` and cannot block the OS's calling thread.
    private func startApply(_ settings: NEPacketTunnelNetworkSettings, fingerprint: String, session: Int) {
        guard let provider = packetTunnelProvider else {
            AppLogger.shared.log("Tunnel settings: provider is gone, dropping the update")
            return
        }
        isApplying = true
        inFlightFingerprint = fingerprint

        let timeout = DispatchWorkItem { [weak self] in
            self?.applyTimedOut(session: session)
        }
        applyTimeoutItem = timeout
        applyQueue.asyncAfter(deadline: .now() + Self.applyTimeout, execute: timeout)

        let v4Count = settings.ipv4Settings?.includedRoutes?.count ?? 0
        let v6Count = settings.ipv6Settings?.includedRoutes?.count ?? 0
        provider.setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else { return }
            let outcome: ApplyOutcome
            if let error {
                outcome = .failed(error)
            } else {
                outcome = .applied
            }
            self.applyQueue.async {
                self.finishApply(session: session, fingerprint: fingerprint, outcome: outcome, v4Count: v4Count, v6Count: v6Count)
            }
        }
    }

    /// On `applyQueue`. A completion from a tunnel that `reset()` has retired, or from an
    /// apply the timeout already gave up on, is ignored: the state it would update no longer
    /// describes anything.
    private func finishApply(session: Int, fingerprint: String, outcome: ApplyOutcome, v4Count: Int, v6Count: Int) {
        guard session == currentSession, isApplying else {
            AppLogger.shared.log("Tunnel settings: ignoring the completion of a superseded apply")
            return
        }
        applyTimeoutItem?.cancel()
        applyTimeoutItem = nil
        let coalesced = coalescedUpdates
        coalescedUpdates = 0
        isApplying = false
        inFlightFingerprint = nil
        switch outcome {
        case .applied:
            lastAppliedFingerprint = fingerprint
            AppLogger.shared.log("Routes set successfully (v4: \(v4Count), v6: \(v6Count), coalesced: \(coalesced))")
        case .failed(let error):
            // A failed apply leaves the OS in an unknown state; forget what was in effect so
            // the next change is applied rather than skipped as a repeat.
            lastAppliedFingerprint = nil
            AppLogger.shared.log("Error assigning routes: \(error.localizedDescription)")
        }
        if let next = pendingApply {
            pendingApply = nil
            startApply(next.settings, fingerprint: next.fingerprint, session: session)
        }
    }

    /// On `applyQueue`. The OS never completed the apply, and it may still be working on
    /// it, so starting the next one underneath would race two reconfigurations of the same
    /// utun. Instead the manager stops applying anything and ends the tunnel through the
    /// provider's error path; the OS, On Demand or the user brings it back, and `reset()`
    /// at that start lifts the suspension. The session check and the teardown happen under
    /// `sessionLock`, so a timeout that belonged to a tunnel already stopped or replaced
    /// issues nothing, and one that is issuing the old tunnel's teardown holds the provider
    /// back from opening the next tunnel until it has.
    private func applyTimedOut(session: Int) {
        guard isApplying else { return }
        sessionLock.lock()
        defer { sessionLock.unlock() }
        guard session == self.session else { return }
        applyTimeoutItem = nil
        clearApplyState()
        suspended = true
        AppLogger.shared.log("Error assigning routes: no completion within \(Int(Self.applyTimeout))s, tearing the tunnel down")
        guard let provider = packetTunnelProvider else { return }
        provider.cancelTunnelWithError(NSError(
            domain: Bundle.main.bundleIdentifier ?? "io.netbird.NetbirdNetworkExtension",
            code: 1006,
            userInfo: [NSLocalizedDescriptionKey: "Applying the tunnel network settings timed out."]
        ))
    }

    /// On `applyQueue`.
    private func clearApplyState() {
        applyTimeoutItem?.cancel()
        applyTimeoutItem = nil
        isApplying = false
        inFlightFingerprint = nil
        lastAppliedFingerprint = nil
        pendingApply = nil
        coalescedUpdates = 0
        suspended = false
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
