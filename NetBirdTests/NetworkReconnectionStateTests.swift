import XCTest
import Network
import NetworkExtension
import NetBirdSDK
@testable import NetBird

final class NetworkReconnectionStateTests: XCTestCase {
    private let wifi = UnderlyingNetwork(interfaces: ["en0:1"])
    private let simA = UnderlyingNetwork(interfaces: ["pdp_ip0:2"], dataServiceIdentifier: "A")
    private let simB = UnderlyingNetwork(interfaces: ["pdp_ip0:2"], dataServiceIdentifier: "B")

    func testSDKStatesPreserveNetworkLoss() {
        XCTAssertEqual(ClientState(sdkState: NetBirdSDKClientStateNoNetwork), .noNetwork)
        XCTAssertEqual(ClientState(sdkState: NetBirdSDKClientStateConnecting), .connecting)
        XCTAssertEqual(ClientState(sdkState: NetBirdSDKClientStateConnected), .connected)
        XCTAssertEqual(ClientState(sdkState: NetBirdSDKClientStateDisconnected), .disconnected)
        XCTAssertEqual(ClientState(sdkState: NetBirdSDKClientStateDisconnecting), .disconnecting)
        XCTAssertNil(ClientState(sdkState: -1))
    }

    func testNetworkLossReassertsUntilNetworkReturns() {
        var state = NetworkReconnectionState()
        // Offline start: the tunnel was never up, so there is nothing to reassert.
        _ = state.update(nil)
        state.connectionChanged(.noNetwork)
        XCTAssertFalse(state.isReasserting)
        _ = state.update(wifi)
        state.connectionChanged(.connected)
        _ = state.update(nil)
        state.connectionChanged(.noNetwork)
        XCTAssertTrue(state.isReasserting)
        state.connectionChanged(.connecting)
        XCTAssertTrue(state.isReasserting)
        // The network is back: new flows must pass even before the core reconnects.
        _ = state.update(simA)
        XCTAssertFalse(state.isReasserting)
        state.connectionChanged(.connected)
        XCTAssertFalse(state.isReasserting)
    }

    func testServerLossWithNetworkDoesNotReassert() {
        // Management or Signal down while peers and routes keep working.
        var state = NetworkReconnectionState()
        _ = state.update(wifi)
        state.connectionChanged(.connected)
        state.connectionChanged(.connecting)
        XCTAssertFalse(state.isReasserting)
        _ = state.update(simA)
        XCTAssertFalse(state.isReasserting)
        state.connectionChanged(.connected)
        XCTAssertFalse(state.isReasserting)
    }

    func testIPv6PrivacyRotationDoesNotChangeNetworkIdentity() throws {
        let mask = try XCTUnwrap(IPv6Address("ffff:ffff:ffff:ffff::"))
        let old = try XCTUnwrap(UnderlyingNetwork.ipv6NetworkIdentity(
            XCTUnwrap(IPv6Address("2001:db8:1:2::1234")), netmask: mask))
        let new = try XCTUnwrap(UnderlyingNetwork.ipv6NetworkIdentity(
            XCTUnwrap(IPv6Address("2001:db8:1:2::5678")), netmask: mask))
        XCTAssertEqual(old, new)
        var state = NetworkReconnectionState()
        _ = state.update(UnderlyingNetwork(interfaces: ["en0:1"], addresses: [old, new]))
        XCTAssertNil(state.update(UnderlyingNetwork(interfaces: ["en0:1"], addresses: [new])))
        let changed = try XCTUnwrap(UnderlyingNetwork.ipv6NetworkIdentity(
            XCTUnwrap(IPv6Address("2001:db8:1:3::5678")), netmask: mask))
        XCTAssertTrue(try XCTUnwrap(state.update(UnderlyingNetwork(interfaces: ["en0:1"], addresses: [changed]))).networkChanged)
    }

    func testIPv6IdentityUsesActualPrefixLength() throws {
        let mask = try XCTUnwrap(IPv6Address("ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff"))
        let first = try XCTUnwrap(UnderlyingNetwork.ipv6NetworkIdentity(
            XCTUnwrap(IPv6Address("2001:db8::1")), netmask: mask))
        let second = try XCTUnwrap(UnderlyingNetwork.ipv6NetworkIdentity(
            XCTUnwrap(IPv6Address("2001:db8::2")), netmask: mask))
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.hasSuffix("/128"))
    }

    func testInitialPathSetsAvailabilityWithoutRefreshingConnections() throws {
        var state = NetworkReconnectionState()
        XCTAssertFalse(try XCTUnwrap(state.update(simA)).networkChanged)
        XCTAssertNil(state.update(simA))
    }

    func testSIMSwitchWithSameInterfaceRefreshesConnections() throws {
        var state = NetworkReconnectionState()
        _ = state.update(simA)
        XCTAssertTrue(try XCTUnwrap(state.update(simB)).networkChanged)
    }

    func testInterfaceAndAddressChangesRefreshConnections() throws {
        for next in [wifi, UnderlyingNetwork(interfaces: ["pdp_ip1:3"], dataServiceIdentifier: "A"),
                     UnderlyingNetwork(interfaces: ["pdp_ip0:2"], addresses: ["10.0.0.2"], dataServiceIdentifier: "A")] {
            var state = NetworkReconnectionState()
            _ = state.update(simA)
            XCTAssertTrue(try XCTUnwrap(state.update(next)).networkChanged)
        }
    }

    func testRecoveryToSameSIMRefreshesConnections() throws {
        var state = NetworkReconnectionState()
        _ = state.update(simA)
        XCTAssertFalse(try XCTUnwrap(state.update(nil)).networkChanged)
        XCTAssertNil(state.update(nil))
        XCTAssertTrue(try XCTUnwrap(state.update(simA)).networkChanged)
    }

    func testInitialOfflinePathIsReportedAndRecoveryRefreshesConnections() throws {
        var state = NetworkReconnectionState()
        XCTAssertFalse(try XCTUnwrap(state.update(nil)).networkChanged)
        XCTAssertTrue(try XCTUnwrap(state.update(simA)).networkChanged)
    }

    func testRapidChangesWhileReconnectingAreNeverDropped() throws {
        var state = NetworkReconnectionState()
        _ = state.update(wifi)
        for next in [simA, simB, simA, wifi] {
            XCTAssertTrue(try XCTUnwrap(state.update(next)).networkChanged)
            XCTAssertNil(state.update(next))
        }
    }

    func testEveryPhysicalNetworkPairRecoversDirectlyAndThroughOutage() throws {
        let networks = [wifi, simA, simB,
                        UnderlyingNetwork(interfaces: ["en1:4"], addresses: ["192.168.2.2"]),
                        UnderlyingNetwork(interfaces: ["en0:1"], supportsIPv4: false)]
        for source in networks {
            for destination in networks {
                var state = NetworkReconnectionState()
                _ = state.update(source)
                state.connectionChanged(.connected)
                if source == destination {
                    XCTAssertNil(state.update(destination))
                } else {
                    XCTAssertTrue(try XCTUnwrap(state.update(destination)).networkChanged)
                }
                _ = state.update(nil)
                state.connectionChanged(.connecting)
                XCTAssertTrue(state.isReasserting)
                XCTAssertTrue(try XCTUnwrap(state.update(destination)).networkChanged)
                state.connectionChanged(.connected)
                XCTAssertFalse(state.isReasserting)
            }
        }
    }

    func testTemporarilyMissingDataServiceIsDetected() throws {
        var state = NetworkReconnectionState()
        _ = state.update(simA)
        let noService = UnderlyingNetwork(interfaces: ["pdp_ip0:2"])
        XCTAssertTrue(try XCTUnwrap(state.update(noService)).networkChanged)
        XCTAssertTrue(try XCTUnwrap(state.update(simB)).networkChanged)
    }

    func testEachTunnelSessionHasDistinctIdentity() {
        XCTAssertNotEqual(NetworkReconnectionState().sessionID, NetworkReconnectionState().sessionID)
    }

    func testStopIgnoresLateNetworkAndSIMCallbacks() {
        var state = NetworkReconnectionState()
        _ = state.update(wifi)
        state.stop()
        XCTAssertNil(state.update(simA))
        XCTAssertNil(state.update(nil))
        XCTAssertFalse(state.isActive)
    }
    func testRequiresConnectionAllowsDialingToActivatePath() {
        XCTAssertTrue(NetworkReconnectionState.allowsConnectionAttempts(.requiresConnection))
        XCTAssertTrue(NetworkReconnectionState.allowsConnectionAttempts(.satisfied))
        XCTAssertFalse(NetworkReconnectionState.allowsConnectionAttempts(.unsatisfied))
    }

    func testUnsatisfiedPathBeforeAnyUsablePathFallsBackToInterfaces() throws {
        var state = NetworkReconnectionState()
        let live = UnderlyingNetwork(interfaces: ["en0", "pdp_ip0"], addresses: ["en0:192.168.6.207"])
        let network = state.resolveNetwork(status: .unsatisfied,
                                           fromPath: { XCTFail("unsatisfied path must not be read"); return wifi },
                                           fromInterfaces: { live })
        XCTAssertEqual(network, live)
        XCTAssertFalse(state.isPathMonitorTrusted)
        XCTAssertEqual(try XCTUnwrap(state.update(network)).reason, .initial)
    }

    func testUnsatisfiedPathWithoutInterfacesKeepsOfflineStart() {
        var state = NetworkReconnectionState()
        XCTAssertNil(state.resolveNetwork(status: .unsatisfied,
                                          fromPath: { wifi },
                                          fromInterfaces: { nil }))
    }

    func testPathMonitorIsTrustedAfterFirstUsablePath() {
        var state = NetworkReconnectionState()
        XCTAssertEqual(state.resolveNetwork(status: .satisfied,
                                            fromPath: { wifi },
                                            fromInterfaces: { XCTFail("usable path needs no check"); return nil }), wifi)
        XCTAssertTrue(state.isPathMonitorTrusted)
        XCTAssertNil(state.resolveNetwork(status: .unsatisfied,
                                          fromPath: { wifi },
                                          fromInterfaces: { XCTFail("trusted monitor needs no check"); return wifi }))
    }

    func testRequiresConnectionDoesNotTrustPathMonitor() {
        var state = NetworkReconnectionState()
        let live = UnderlyingNetwork(interfaces: ["en0"], addresses: ["en0:192.168.6.207"])
        XCTAssertEqual(state.resolveNetwork(status: .requiresConnection,
                                            fromPath: { wifi },
                                            fromInterfaces: { XCTFail("path allows connection attempts"); return nil }), wifi)
        XCTAssertFalse(state.isPathMonitorTrusted)
        XCTAssertEqual(state.resolveNetwork(status: .unsatisfied,
                                            fromPath: { XCTFail("unsatisfied path must not be read"); return wifi },
                                            fromInterfaces: { live }), live)
    }

    func testInterfaceFallbackSwitchingToPathRefreshesConnections() throws {
        var state = NetworkReconnectionState()
        let live = UnderlyingNetwork(interfaces: ["en0"], addresses: ["en0:192.168.6.207"])
        _ = state.update(state.resolveNetwork(status: .unsatisfied, fromPath: { wifi }, fromInterfaces: { live }))
        let next = state.resolveNetwork(status: .satisfied, fromPath: { wifi }, fromInterfaces: { live })
        XCTAssertTrue(try XCTUnwrap(state.update(next)).networkChanged)
    }

    func testOnlyPhysicalInterfacesWithUsableAddressesCount() {
        for name in ["en0", "en2", "pdp_ip0", "pdp_ip1"] {
            XCTAssertTrue(UnderlyingNetwork.isPhysicalInterface(name), name)
        }
        for name in ["utun3", "lo0", "awdl0", "llw0", "anpi0", "ap1", "bridge100"] {
            XCTAssertFalse(UnderlyingNetwork.isPhysicalInterface(name), name)
        }
        for host in ["192.168.6.207", "10.183.44.121", "2a00:1450:4001:80b::200e"] {
            XCTAssertTrue(UnderlyingNetwork.isUsableAddress(host), host)
        }
        for host in ["169.254.10.1", "127.0.0.1", "0.0.0.0", "fe80::498:1a54:b8c4:9f3f%en0", "::1", "::", "garbage"] {
            XCTAssertFalse(UnderlyingNetwork.isUsableAddress(host), host)
        }
    }

    private func ipv6Entry(_ interface: String, _ host: String) throws -> UnderlyingNetwork.InterfaceAddress {
        let mask = try XCTUnwrap(IPv6Address("ffff:ffff:ffff:ffff::"))
        let prefix = try XCTUnwrap(UnderlyingNetwork.ipv6NetworkIdentity(XCTUnwrap(IPv6Address(host)), netmask: mask))
        return UnderlyingNetwork.InterfaceAddress(interface: interface, flags: UInt32(IFF_UP | IFF_RUNNING),
                                                  host: host, isIPv6: true, identity: "\(interface):\(prefix)")
    }

    func testInterfaceFallbackIPv6OnlyPrefixChangeRefreshesConnections() throws {
        let first = try XCTUnwrap(UnderlyingNetwork.fromInterfaceAddresses(
            [ipv6Entry("en0", "2001:db8:1:2::1234")], dataServiceIdentifier: nil))
        XCTAssertFalse(first.supportsIPv4)
        XCTAssertTrue(first.supportsIPv6)
        let rotated = try XCTUnwrap(UnderlyingNetwork.fromInterfaceAddresses(
            [ipv6Entry("en0", "2001:db8:1:2::5678")], dataServiceIdentifier: nil))
        let moved = try XCTUnwrap(UnderlyingNetwork.fromInterfaceAddresses(
            [ipv6Entry("en0", "2001:db8:1:3::1234")], dataServiceIdentifier: nil))
        var state = NetworkReconnectionState()
        _ = state.update(first)
        XCTAssertNil(state.update(rotated))
        XCTAssertEqual(try XCTUnwrap(state.update(moved)).reason, .changed)
    }

    func testInterfaceFallbackDataServiceChangeRefreshesConnections() throws {
        let entries = [try ipv6Entry("pdp_ip0", "2001:db8:1:2::1234")]
        let simA = try XCTUnwrap(UnderlyingNetwork.fromInterfaceAddresses(entries, dataServiceIdentifier: "A"))
        let simB = try XCTUnwrap(UnderlyingNetwork.fromInterfaceAddresses(entries, dataServiceIdentifier: "B"))
        XCTAssertEqual(simA.dataServiceIdentifier, "A")
        var state = NetworkReconnectionState()
        _ = state.update(simA)
        XCTAssertEqual(try XCTUnwrap(state.update(simB)).reason, .changed)
        let wifiOnly = try XCTUnwrap(UnderlyingNetwork.fromInterfaceAddresses(
            [ipv6Entry("en0", "2001:db8:1:2::1234")], dataServiceIdentifier: "A"))
        XCTAssertNil(wifiOnly.dataServiceIdentifier)
    }

    /// One unsatisfied path report on a monitor that is not trusted yet.
    private func reportUnsatisfied(_ state: inout NetworkReconnectionState, interfaces: UnderlyingNetwork?) {
        _ = state.update(state.resolveNetwork(status: .unsatisfied, fromPath: { wifi }, fromInterfaces: { interfaces }))
    }

    func testInterfaceRecheckNeededOnlyForNoNetworkOnUntrustedMonitor() {
        var state = NetworkReconnectionState()
        XCTAssertFalse(state.needsInterfaceRecheck, "no result yet")
        reportUnsatisfied(&state, interfaces: nil)
        XCTAssertTrue(state.needsInterfaceRecheck)
        reportUnsatisfied(&state, interfaces: UnderlyingNetwork(interfaces: ["en0"], addresses: ["en0:192.168.6.207"]))
        XCTAssertFalse(state.needsInterfaceRecheck, "network found")
        reportUnsatisfied(&state, interfaces: nil)
        XCTAssertTrue(state.needsInterfaceRecheck, "network lost again")
        state.stop()
        XCTAssertFalse(state.needsInterfaceRecheck, "stopped")
    }

    func testInterfaceRecheckNotNeededOnceMonitorIsTrusted() {
        var state = NetworkReconnectionState()
        reportUnsatisfied(&state, interfaces: nil)
        XCTAssertTrue(state.needsInterfaceRecheck)
        _ = state.update(state.resolveNetwork(status: .satisfied, fromPath: { wifi }, fromInterfaces: { nil }))
        XCTAssertFalse(state.needsInterfaceRecheck)
        // A trusted monitor's outage is real: the core waits for the next path event.
        reportUnsatisfied(&state, interfaces: nil)
        XCTAssertFalse(state.needsInterfaceRecheck)
    }

    func testInterfaceRecheckFollowsSatisfiedOnlyTrust() {
        var state = NetworkReconnectionState()
        // requiresConnection is not paused, so nothing to re-check, but it does not trust the monitor.
        _ = state.update(state.resolveNetwork(status: .requiresConnection, fromPath: { wifi }, fromInterfaces: { nil }))
        XCTAssertFalse(state.needsInterfaceRecheck)
        reportUnsatisfied(&state, interfaces: nil)
        XCTAssertTrue(state.needsInterfaceRecheck, "requiresConnection then unsatisfied still re-checks")
        _ = state.update(state.resolveNetwork(status: .requiresConnection, fromPath: { wifi }, fromInterfaces: { nil }))
        XCTAssertFalse(state.needsInterfaceRecheck, "a path that allows attempts gives a network")
    }

    private final class FakeSchedule {
        var ticks: [(delay: TimeInterval, work: DispatchWorkItem)] = []
        lazy var timer = InterfaceRecheckTimer { [unowned self] delay, work in self.ticks.append((delay, work)) }
    }

    func testInterfaceRecheckTimerStartsOnceAndBacksOffToCap() throws {
        let fake = FakeSchedule()
        var fired = 0
        func update() { fake.timer.update(needed: true) { fired += 1 } }
        update()
        update()
        XCTAssertTrue(fake.timer.isRunning)
        XCTAssertEqual(fake.ticks.count, 1, "a pending tick is not armed twice")
        var delays: [TimeInterval] = []
        for _ in 0..<9 {
            let tick = try XCTUnwrap(fake.ticks.last)
            delays.append(tick.delay)
            tick.work.perform()
            XCTAssertTrue(fake.timer.isRunning, "running while the tick is handled")
            update()
        }
        XCTAssertEqual(fired, 9)
        XCTAssertEqual(delays, [1, 2, 4, 8, 16, 32, 60, 60, 60])
        XCTAssertEqual(InterfaceRecheckTimer.initialDelay, delays.first)
        XCTAssertEqual(InterfaceRecheckTimer.maxDelay, delays.last)
    }

    func testInterfaceRecheckTimerStopsWhenNoLongerNeeded() throws {
        let fake = FakeSchedule()
        var fired = 0
        fake.timer.update(needed: true) { fired += 1 }
        try XCTUnwrap(fake.ticks.last).work.perform()
        fake.timer.update(needed: true) { fired += 1 }
        fake.timer.update(needed: false) { fired += 1 }
        XCTAssertFalse(fake.timer.isRunning)
        let pending = try XCTUnwrap(fake.ticks.last)
        XCTAssertTrue(pending.work.isCancelled)
        // A tick already handed to the queue must not fire after the stop.
        pending.work.perform()
        XCTAssertEqual(fired, 1)
        // A later outage starts over at the short delay.
        fake.timer.update(needed: true) { fired += 1 }
        XCTAssertEqual(fake.ticks.last?.delay, InterfaceRecheckTimer.initialDelay)
    }

    func testInterfaceRecheckTimerCancelDropsQueuedTick() throws {
        let fake = FakeSchedule()
        var fired = 0
        fake.timer.update(needed: true) { fired += 1 }
        fake.timer.cancel()
        XCTAssertFalse(fake.timer.isRunning)
        try XCTUnwrap(fake.ticks.last).work.perform()
        XCTAssertEqual(fired, 0)
        fake.timer.update(needed: false) { fired += 1 }
        XCTAssertEqual(fake.ticks.count, 1, "not needed arms nothing")
    }

    func testInterfaceRecheckTimerReleasesTickAndOwner() {
        weak var weakTimer: InterfaceRecheckTimer?
        var work: DispatchWorkItem?
        var fired = 0
        do {
            let timer = InterfaceRecheckTimer { _, item in work = item }
            weakTimer = timer
            timer.update(needed: true) { fired += 1 }
        }
        XCTAssertNil(weakTimer, "a queued tick must not keep the timer alive")
        work?.perform()
        XCTAssertEqual(fired, 0)
    }

    /// Offline start, Wi-Fi joins later: the re-check, not a path event, finds it.
    func testInterfaceRecheckFindsLateWiFiAndStops() throws {
        let fake = FakeSchedule()
        var state = NetworkReconnectionState()
        var interfaces: UnderlyingNetwork?
        var changes: [NetworkReconnectionState.Change.Reason] = []
        func handle() {
            if let change = state.update(state.resolveNetwork(status: .unsatisfied,
                                                              fromPath: { wifi }, fromInterfaces: { interfaces })) {
                changes.append(change.reason)
            }
            fake.timer.update(needed: state.needsInterfaceRecheck, fire: handle)
        }
        handle()
        try XCTUnwrap(fake.ticks.last).work.perform()
        try XCTUnwrap(fake.ticks.last).work.perform()
        XCTAssertEqual(fake.ticks.count, 3)
        interfaces = UnderlyingNetwork(interfaces: ["en0"], addresses: ["en0:192.168.6.207"])
        try XCTUnwrap(fake.ticks.last).work.perform()
        XCTAssertEqual(changes, [.initial, .recovered])
        XCTAssertFalse(fake.timer.isRunning)
        XCTAssertEqual(fake.ticks.count, 3, "nothing armed after the network is found")
    }

    func testInitialConnectionDoesNotReassert() {
        var state = NetworkReconnectionState()
        state.connectionChanged(.connecting)
        XCTAssertFalse(state.isReasserting)
        state.connectionChanged(.connected)
        XCTAssertFalse(state.isReasserting)
    }

    func testHandoverWithoutOutageDoesNotReassert() {
        var state = NetworkReconnectionState()
        _ = state.update(simA)
        state.connectionChanged(.connected)
        _ = state.update(simB)
        XCTAssertFalse(state.isReasserting)
        state.connectionChanged(.connecting)
        XCTAssertFalse(state.isReasserting)
        _ = state.update(simA)
        XCTAssertFalse(state.isReasserting)
        state.connectionChanged(.connected)
        XCTAssertFalse(state.isReasserting)
    }

    func testStoppingClearsReassertingAndIgnoresLateConnectionEvents() {
        var state = NetworkReconnectionState()
        _ = state.update(wifi)
        state.connectionChanged(.connected)
        _ = state.update(nil)
        XCTAssertTrue(state.isReasserting)
        state.stop()
        XCTAssertFalse(state.isReasserting)
        state.connectionChanged(.connected)
        state.connectionChanged(.connecting)
        XCTAssertFalse(state.isReasserting)
    }

    func testCoreDisconnectStatesKeepReasserting() {
        // The core sends these inside its retry loop, so they must not clear reasserting.
        for coreState: ClientState in [.disconnecting, .disconnected] {
            var state = NetworkReconnectionState()
            _ = state.update(wifi)
            state.connectionChanged(.connected)
            state.connectionChanged(coreState)
            _ = state.update(nil)
            XCTAssertTrue(state.isReasserting)
        }
    }

    func testStopClearsReasserting() {
        var state = NetworkReconnectionState()
        _ = state.update(wifi)
        state.connectionChanged(.connected)
        _ = state.update(nil)
        XCTAssertTrue(state.isReasserting)
        state.stop()
        XCTAssertFalse(state.isReasserting)
    }

    func testGatewayAndIPFamilyChangesRefreshSameInterface() throws {
        let initial = UnderlyingNetwork(interfaces: ["en0:1"], gateways: ["192.168.1.1"])
        for next in [
            UnderlyingNetwork(interfaces: ["en0:1"], gateways: ["192.168.1.254"]),
            UnderlyingNetwork(interfaces: ["en0:1"], gateways: ["192.168.1.1"], supportsIPv4: false),
            UnderlyingNetwork(interfaces: ["en0:1"], gateways: ["192.168.1.1"], supportsIPv6: false)
        ] {
            var state = NetworkReconnectionState()
            _ = state.update(initial)
            XCTAssertTrue(try XCTUnwrap(state.update(next)).networkChanged)
        }
    }

    func testSnapshotOrderingDoesNotTriggerReconnect() {
        let first = UnderlyingNetwork(interfaces: ["b", "a"], addresses: ["2", "1"], gateways: ["y", "x"])
        let second = UnderlyingNetwork(interfaces: ["a", "b"], addresses: ["1", "2"], gateways: ["x", "y"])
        XCTAssertEqual(first, second)
    }

    func testRepeatedWakePreservesHealthyConnections() {
        var state = NetworkReconnectionState()
        _ = state.update(wifi)
        state.connectionChanged(.connected)
        for _ in 0..<24 {
            XCTAssertNil(state.update(wifi), "An unchanged wake must not sweep healthy connections")
        }
        XCTAssertFalse(state.isReasserting)
    }

    func testWakeReconcilesChangedPathAndOfflineRecovery() throws {
        var state = NetworkReconnectionState()
        _ = state.update(wifi)
        XCTAssertEqual(try XCTUnwrap(state.update(simA)).reason, .changed)
        XCTAssertEqual(try XCTUnwrap(state.update(nil)).reason, .unavailable)
        XCTAssertNil(state.update(nil))
        XCTAssertEqual(try XCTUnwrap(state.update(simA)).reason, .recovered)
        XCTAssertNil(state.update(simA))
        state.stop()
        XCTAssertNil(state.update(wifi))
    }

    func testCallOnOtherSIMAndReturnRefreshOncePerTransition() throws {
        for hasOutage in [false, true] {
            var state = NetworkReconnectionState()
            _ = state.update(simA)
            state.connectionChanged(.connected)
            for next in [simB, simA] {
                if hasOutage {
                    XCTAssertFalse(try XCTUnwrap(state.update(nil)).networkChanged)
                    state.connectionChanged(.connecting)
                    XCTAssertTrue(state.isReasserting)
                }
                XCTAssertTrue(try XCTUnwrap(state.update(next)).networkChanged)
                // Path, telephony and wake callbacks can report the same handover.
                XCTAssertNil(state.update(next))
                XCTAssertNil(state.update(next))
                state.connectionChanged(.connected)
                XCTAssertFalse(state.isReasserting)
            }
        }
    }

    func testInitialEngineCallbacksLoseOwnershipAfterReplacement() {
        var state = NetworkReconnectionState()
        let session = state.sessionID
        XCTAssertTrue(state.acceptsCallback(sessionID: session, engineGeneration: 1, currentEngineGeneration: 1))
        // Delayed success and error completions use the same ownership gate.
        XCTAssertFalse(state.acceptsCallback(sessionID: session, engineGeneration: 1, currentEngineGeneration: 2))
        XCTAssertTrue(state.acceptsCallback(sessionID: session, engineGeneration: 2, currentEngineGeneration: 2))
        XCTAssertFalse(state.acceptsCallback(sessionID: UUID(), engineGeneration: 2, currentEngineGeneration: 2))
        state.stop()
        XCTAssertFalse(state.acceptsCallback(sessionID: session, engineGeneration: 2, currentEngineGeneration: 2))
    }

    @MainActor
    func testAppDistinguishesNoNetworkFromReconnecting() {
        let model = ViewModel()
        model.managementStatus = .noNetwork
        model.applyExtensionStatus(.reasserting)
        XCTAssertEqual(model.vpnDisplayState, .connecting)
        XCTAssertEqual(model.extensionStateText, "No network")
        model.managementStatus = .connecting
        model.applyExtensionStatus(.reasserting)
        XCTAssertEqual(model.extensionStateText, "Reconnecting...")
    }

    @MainActor
    func testAppAcceptsReassertingAndDisplaysReconnecting() {
        let model = ViewModel()
        model.extensionState = .connected
        model.applyExtensionStatus(.reasserting)
        XCTAssertEqual(model.extensionState, .reasserting)
        XCTAssertEqual(model.vpnDisplayState, .connecting)
        XCTAssertEqual(model.extensionStateText, "Reconnecting...")
        model.applyExtensionStatus(.disconnecting)
        XCTAssertEqual(model.vpnDisplayState, .disconnecting)
        model.applyExtensionStatus(.disconnected)
        XCTAssertEqual(model.vpnDisplayState, .disconnected)
    }

}


final class ConnectionListenerStartupTests: XCTestCase {
    private final class AuthFailedAdapter: NetBirdAdapter {
        override func needsLoginCached() -> Bool { true }
    }

    private func makeAdapter() throws -> AuthFailedAdapter {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return try XCTUnwrap(AuthFailedAdapter(
            with: PacketTunnelProviderSettingsManager(with: PacketTunnelProvider()),
            configPath: directory.appendingPathComponent("config.json").path,
            statePath: directory.appendingPathComponent("state.json").path))
    }

    func testStaleDisconnectIsIgnoredButNewAuthenticationFailureIsDelivered() throws {
        let adapter = try makeAdapter()
        var loginRequired = 0
        var states: [ClientState] = []
        adapter.onLoginRequired = { loginRequired += 1 }
        let listener = ConnectionListener(adapter: adapter, onConnectionChanged: { states.append($0) }) { _ in }

        // The SDK replays the legacy callback before OnStateChanged.
        listener.onDisconnected()
        listener.onStateChanged(NetBirdSDKClientStateDisconnected)
        XCTAssertEqual(loginRequired, 0)
        XCTAssertTrue(states.isEmpty)

        listener.onConnecting()
        listener.onStateChanged(NetBirdSDKClientStateConnecting)
        listener.onDisconnected()
        listener.onStateChanged(NetBirdSDKClientStateDisconnected)
        XCTAssertEqual(loginRequired, 1)
        XCTAssertEqual(states, [.connecting, .disconnected])

        // Each engine start gets a new listener, even when reusing the adapter.
        let nextListener = ConnectionListener(adapter: adapter) { _ in }
        nextListener.onDisconnected()
        XCTAssertEqual(loginRequired, 1)
    }

    func testOfflineStartStillDeliversAuthenticationFailure() throws {
        let adapter = try makeAdapter()
        var loginRequired = 0
        adapter.onLoginRequired = { loginRequired += 1 }
        let listener = ConnectionListener(adapter: adapter) { _ in }
        // NoNetwork has no legacy onConnecting callback.
        listener.onStateChanged(NetBirdSDKClientStateNoNetwork)
        listener.onDisconnected()
        XCTAssertEqual(loginRequired, 1)
    }
}
