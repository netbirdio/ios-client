import XCTest
import Network
import NetworkExtension
@testable import NetBird

final class NetworkReconnectionStateTests: XCTestCase {
    private let wifi = UnderlyingNetwork(interfaces: ["en0:1"])
    private let simA = UnderlyingNetwork(interfaces: ["pdp_ip0:2"], dataServiceIdentifier: "A")
    private let simB = UnderlyingNetwork(interfaces: ["pdp_ip0:2"], dataServiceIdentifier: "B")

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

    func testTemporarilyMissingDataServiceIsDetected() throws {
        var state = NetworkReconnectionState()
        _ = state.update(simA)
        let noService = UnderlyingNetwork(interfaces: ["pdp_ip0:2"])
        XCTAssertTrue(try XCTUnwrap(state.update(noService)).networkChanged)
        XCTAssertTrue(try XCTUnwrap(state.update(simB)).networkChanged)
    }

    func testRecoveryDoesNotCompleteTunnelStartAgain() {
        var state = NetworkReconnectionState()
        XCTAssertTrue(state.completeStart())
        _ = state.update(simA)
        _ = state.update(simB)
        XCTAssertFalse(state.completeStart())
        XCTAssertNotEqual(state.sessionID, NetworkReconnectionState().sessionID)
    }

    func testStopIgnoresLateNetworkAndSIMCallbacks() {
        var state = NetworkReconnectionState()
        _ = state.update(wifi)
        state.stop()
        XCTAssertNil(state.update(simA))
        XCTAssertNil(state.update(nil))
        XCTAssertFalse(state.isActive)
        XCTAssertFalse(state.completeStart())
    }
    func testRequiresConnectionAllowsDialingToActivatePath() {
        XCTAssertTrue(NetworkReconnectionState.allowsConnectionAttempts(.requiresConnection))
        XCTAssertTrue(NetworkReconnectionState.allowsConnectionAttempts(.satisfied))
        XCTAssertFalse(NetworkReconnectionState.allowsConnectionAttempts(.unsatisfied))
    }

    func testInitialConnectionDoesNotReassert() {
        var state = NetworkReconnectionState()
        state.connectionChanged(.connecting)
        XCTAssertFalse(state.isReasserting)
        state.connectionChanged(.connected)
        XCTAssertFalse(state.isReasserting)
    }

    func testReassertingFollowsConnectionRecoveryNotPathNotifications() {
        var state = NetworkReconnectionState()
        _ = state.update(simA)
        state.connectionChanged(.connected)
        _ = state.update(simB)
        XCTAssertFalse(state.isReasserting)
        state.connectionChanged(.connecting)
        XCTAssertTrue(state.isReasserting)
        _ = state.update(simA)
        XCTAssertTrue(state.isReasserting)
        state.connectionChanged(.connected)
        XCTAssertFalse(state.isReasserting)
    }

    func testStoppingClearsReassertingAndIgnoresLateConnectionEvents() {
        var state = NetworkReconnectionState()
        state.connectionChanged(.connected)
        state.connectionChanged(.connecting)
        XCTAssertTrue(state.isReasserting)
        state.stop()
        XCTAssertFalse(state.isReasserting)
        state.connectionChanged(.connected)
        state.connectionChanged(.connecting)
        XCTAssertFalse(state.isReasserting)
    }

    func testTerminalDisconnectionClearsReasserting() {
        for terminalState: ClientState in [.disconnecting, .disconnected] {
            var state = NetworkReconnectionState()
            state.connectionChanged(.connected)
            state.connectionChanged(.connecting)
            XCTAssertTrue(state.isReasserting)
            state.connectionChanged(terminalState)
            XCTAssertFalse(state.isReasserting)
        }
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

    func testWakeRefreshesUnchangedPathButNeverDialsOfflineOrAfterStop() throws {
        var state = NetworkReconnectionState()
        _ = state.update(wifi)
        XCTAssertTrue(try XCTUnwrap(state.update(wifi, forceRefresh: true)).networkChanged)
        XCTAssertNil(state.update(wifi))
        XCTAssertFalse(try XCTUnwrap(state.update(nil, forceRefresh: true)).networkChanged)
        XCTAssertTrue(try XCTUnwrap(state.update(wifi)).networkChanged)
        state.stop()
        XCTAssertNil(state.update(wifi, forceRefresh: true))
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
