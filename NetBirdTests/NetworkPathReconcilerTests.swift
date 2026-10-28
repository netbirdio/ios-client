//
//  NetworkPathReconcilerTests.swift
//  NetBirdTests
//

import XCTest
import Network
@testable import NetBird

final class NetworkPathReconcilerTests: XCTestCase {

    private let wifi = NetworkPathSnapshot.Interface(type: .wifi, name: "en0")
    private let cellular = NetworkPathSnapshot.Interface(type: .cellular, name: "pdp_ip0")

    private func satisfied(_ interface: NetworkPathSnapshot.Interface?) -> NetworkPathSnapshot {
        NetworkPathSnapshot(isSatisfied: true, primaryInterface: interface)
    }

    private let unsatisfied = NetworkPathSnapshot(isSatisfied: false, primaryInterface: nil)

    func testFirstPathIsSilent() {
        var reconciler = NetworkPathReconciler()
        XCTAssertEqual(reconciler.handle(satisfied(wifi)), [])
    }

    func testRepeatedIdenticalPathIsSilent() {
        var reconciler = NetworkPathReconciler()
        _ = reconciler.handle(satisfied(wifi))
        XCTAssertEqual(reconciler.handle(satisfied(wifi)), [])
        XCTAssertEqual(reconciler.handle(satisfied(wifi)), [])
    }

    func testPrimaryInterfaceTypeChangeNotifies() {
        var reconciler = NetworkPathReconciler()
        _ = reconciler.handle(satisfied(wifi))
        XCTAssertEqual(reconciler.handle(satisfied(cellular)), [.networkChanged])
        XCTAssertEqual(reconciler.handle(satisfied(wifi)), [.networkChanged])
    }

    func testPrimaryInterfaceNameChangeNotifies() {
        var reconciler = NetworkPathReconciler()
        _ = reconciler.handle(satisfied(cellular))
        let otherCellular = NetworkPathSnapshot.Interface(type: .cellular, name: "pdp_ip1")
        XCTAssertEqual(reconciler.handle(satisfied(otherCellular)), [.networkChanged])
    }

    func testPathWithoutPrimaryInterfaceIsSilent() {
        var reconciler = NetworkPathReconciler()
        _ = reconciler.handle(satisfied(wifi))
        XCTAssertEqual(reconciler.handle(satisfied(nil)), [])
        XCTAssertEqual(reconciler.handle(satisfied(wifi)), [])
    }

    // A switch between two Wi-Fi networks keeps en0 and shows only as a short blip.
    func testBlipNotifiesOnReturnWithoutReportingLoss() {
        var reconciler = NetworkPathReconciler()
        _ = reconciler.handle(satisfied(wifi))
        XCTAssertEqual(reconciler.handle(unsatisfied), [])
        XCTAssertEqual(reconciler.handle(satisfied(wifi)), [.networkChanged])
    }

    func testRepeatedUnsatisfiedPathsNotifyOnceOnReturn() {
        var reconciler = NetworkPathReconciler()
        _ = reconciler.handle(satisfied(wifi))
        _ = reconciler.handle(unsatisfied)
        _ = reconciler.handle(unsatisfied)
        XCTAssertEqual(reconciler.handle(satisfied(cellular)), [.networkChanged])
        XCTAssertEqual(reconciler.handle(satisfied(cellular)), [])
    }

    func testSustainedLossReportsUnavailableOnce() {
        var reconciler = NetworkPathReconciler()
        _ = reconciler.handle(satisfied(wifi))
        _ = reconciler.handle(unsatisfied)
        XCTAssertEqual(reconciler.confirmLoss(), [.networkAvailable(false)])
        XCTAssertEqual(reconciler.confirmLoss(), [])
    }

    func testRecoveryAfterSustainedLossNotifiesBeforeAvailable() {
        var reconciler = NetworkPathReconciler()
        _ = reconciler.handle(satisfied(wifi))
        _ = reconciler.handle(unsatisfied)
        _ = reconciler.confirmLoss()
        XCTAssertEqual(reconciler.handle(satisfied(wifi)), [.networkChanged, .networkAvailable(true)])
        XCTAssertEqual(reconciler.handle(satisfied(wifi)), [])
    }

    func testConfirmLossWhileSatisfiedIsIgnored() {
        var reconciler = NetworkPathReconciler()
        _ = reconciler.handle(satisfied(wifi))
        XCTAssertEqual(reconciler.confirmLoss(), [])
        _ = reconciler.handle(unsatisfied)
        _ = reconciler.handle(satisfied(wifi))
        XCTAssertEqual(reconciler.confirmLoss(), [])
    }

    func testUnsatisfiedFirstPathNotifiesOnReturn() {
        var reconciler = NetworkPathReconciler()
        XCTAssertEqual(reconciler.handle(unsatisfied), [])
        XCTAssertEqual(reconciler.handle(satisfied(wifi)), [.networkChanged])
    }

    func testResetForgetsPreviousState() {
        var reconciler = NetworkPathReconciler()
        _ = reconciler.handle(satisfied(wifi))
        _ = reconciler.handle(unsatisfied)
        _ = reconciler.confirmLoss()
        reconciler.reset()
        XCTAssertEqual(reconciler.handle(satisfied(cellular)), [])
        XCTAssertEqual(reconciler.confirmLoss(), [])
    }
}
