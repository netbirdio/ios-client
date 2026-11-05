import XCTest
@testable import NetBird

final class NetworkSettingsLogLineTests: XCTestCase {
    private func line(
        ipv4: [String] = [],
        ipv6: [String] = [],
        previous: [String] = [],
        dns: [String] = [],
        match: [String] = [],
        search: [String] = []
    ) -> String {
        NetworkSettingsLogLine.make(
            ipv4Routes: ipv4,
            ipv6Routes: ipv6,
            previousRoutes: previous,
            dnsServers: dns,
            matchDomains: match,
            searchDomains: search
        )
    }

    private func prefixes(_ count: Int, from start: Int = 0) -> [String] {
        (start..<(start + count)).map { "10.\($0 / 256).\($0 % 256).0/24" }
    }

    func testFirstListCountsEveryRouteAsAdded() {
        XCTAssertEqual(
            line(ipv4: ["100.64.0.1/32", "10.0.0.0/8"], ipv6: ["fd00::/64"]),
            "ipv4=2 ipv6=1 default4=no default6=no added=[ 100.64.0.1/32 10.0.0.0/8 fd00::/64 ] removed=[ ] dns=[] matchDomains=[ ] searchDomains=[ ]"
        )
    }

    func testShowsOnlyChangesSinceThePreviousList() {
        let result = line(ipv4: ["10.0.0.0/8", "10.1.0.0/16"], previous: ["10.0.0.0/8", "10.2.0.0/16"])
        XCTAssertTrue(result.contains("ipv4=2 "))
        XCTAssertTrue(result.contains("added=[ 10.1.0.0/16 ] removed=[ 10.2.0.0/16 ]"))
    }

    func testDefaultRouteFlags() {
        let v4 = line(ipv4: ["0.0.0.0/0"])
        XCTAssertTrue(v4.contains("default4=yes default6=no"))
        let v6 = line(ipv6: ["::/0"])
        XCTAssertTrue(v6.contains("default4=no default6=yes"))
    }

    func testDefaultRouteFlagStaysWhenNothingChanged() {
        let result = line(ipv4: ["0.0.0.0/0"], previous: ["0.0.0.0/0"])
        XCTAssertTrue(result.contains("default4=yes"))
        XCTAssertTrue(result.contains("added=[ ] removed=[ ]"))
    }

    func testLongListIsCappedAndCountsTheRest() {
        let result = line(ipv4: prefixes(214))
        XCTAssertTrue(result.contains("ipv4=214 "))
        XCTAssertTrue(result.contains("+164 more ]"))
        XCTAssertEqual(result.components(separatedBy: "/24").count - 1, NetworkSettingsLogLine.maxPrefixes)
    }

    func testCapIsSharedBetweenAddedAndRemoved() {
        let result = line(ipv4: prefixes(60), previous: prefixes(60, from: 1000))
        XCTAssertEqual(result.components(separatedBy: "/24").count - 1, NetworkSettingsLogLine.maxPrefixes)
        XCTAssertEqual(result.components(separatedBy: "+35 more").count - 1, 2)
    }

    func testShortRemovedListLeavesRoomForAdded() {
        let result = line(ipv4: prefixes(60), previous: prefixes(10, from: 1000))
        XCTAssertTrue(result.contains("+20 more ]"))
        XCTAssertFalse(result.contains("removed=[ 10.3.232.0/24 10.3.233.0/24 +"))
    }

    func testLineStaysSmallOnLargeAccount() {
        let result = line(ipv4: prefixes(5000))
        XCTAssertLessThan(result.utf8.count, 2048)
    }

    func testDomainsUseTheFormTheAnonymizerMasks() {
        let result = line(match: ["corp.example.com", ""], search: ["example.org"])
        XCTAssertTrue(result.contains("matchDomains=[ domain=corp.example.com \"\" ]"))
        XCTAssertTrue(result.contains("searchDomains=[ domain=example.org ]"))
    }

    func testLongDomainListIsCappedAndCountsTheRest() {
        let domains = (0..<30).map { "d\($0).example.com" }
        let result = line(search: domains)
        XCTAssertTrue(result.contains("+10 more ]"))
        XCTAssertEqual(result.components(separatedBy: "domain=").count - 1, NetworkSettingsLogLine.maxDomains)
    }

    func testRouteNameWithoutDotStaysReadable() {
        XCTAssertEqual(NetworkSettingsLogLine.name("exit-docker"), "exit-docker")
        XCTAssertEqual(NetworkSettingsLogLine.name("corp.example.com"), "domain=corp.example.com")
    }
}
