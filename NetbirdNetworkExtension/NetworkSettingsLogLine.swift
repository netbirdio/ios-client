import Foundation

/// Text of the `Network settings applied` log line.
///
/// The Swift log is deleted when it passes 100 KB, and an account can have thousands of routes.
/// The line holds route counts and the changes since the last line, not the full list.
enum NetworkSettingsLogLine {
    /// Most prefixes printed in one line, added and removed together.
    static let maxPrefixes = 50

    static func make(
        ipv4Routes: [String],
        ipv6Routes: [String],
        previousRoutes: [String],
        dnsServers: [String],
        matchDomains: [String],
        searchDomains: [String]
    ) -> String {
        let routes = ipv4Routes + ipv6Routes
        let current = Set(routes)
        let previous = Set(previousRoutes)
        let added = routes.filter { !previous.contains($0) }
        let removed = previousRoutes.filter { !current.contains($0) }
        let shownAdded = min(added.count, max(maxPrefixes / 2, maxPrefixes - removed.count))
        let shownRemoved = min(removed.count, maxPrefixes - shownAdded)

        return "ipv4=\(ipv4Routes.count) ipv6=\(ipv6Routes.count)"
            + " default4=\(ipv4Routes.contains("0.0.0.0/0") ? "yes" : "no")"
            + " default6=\(ipv6Routes.contains("::/0") ? "yes" : "no")"
            + " added=\(prefixList(added, shown: shownAdded))"
            + " removed=\(prefixList(removed, shown: shownRemoved))"
            + " dns=\(dnsServers)"
            + " matchDomains=\(domainList(matchDomains))"
            + " searchDomains=\(domainList(searchDomains))"
    }

    /// The bundle anonymizer masks a name it has not seen only in the `domain=<name>` form.
    static func name(_ name: String) -> String {
        name.contains(".") ? "domain=\(name)" : name
    }

    private static func prefixList(_ prefixes: [String], shown: Int) -> String {
        var items = Array(prefixes.prefix(shown))
        if prefixes.count > shown {
            items.append("+\(prefixes.count - shown) more")
        }
        return bracketed(items)
    }

    private static func domainList(_ domains: [String]) -> String {
        bracketed(domains.map { $0.isEmpty ? "\"\"" : name($0) })
    }

    /// Spaces around the items: the anonymizer would read a closing bracket as part of a name.
    private static func bracketed(_ items: [String]) -> String {
        items.isEmpty ? "[ ]" : "[ \(items.joined(separator: " ")) ]"
    }
}
