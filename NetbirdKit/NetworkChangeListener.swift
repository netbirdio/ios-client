//
//  RouteNotifier.swift
//  NetBirdiOS
//
//  Created by Pascal Fischer on 03.08.23.
//


import Foundation
import NetBirdSDK
import NetworkExtension
import os

enum IPAddressType {
    case ipv4
    case ipv6
    case invalid
}

class NetworkChangeListener: NSObject, NetBirdSDKNetworkChangeListenerProtocol {
    // The Go engine retains this listener for the lifetime of the SDK client it was
    // created with. When the adapter is swapped/torn down (e.g. profile switch or a
    // restart triggered by wifi<->cellular flapping) the OLD client can still be
    // spinning down and fire a late callback into THIS (now-stale) listener. Without
    // a guard that callback would reach into a tunnelManager whose owning provider has
    // already been deallocated, dereferencing a freed object -> EXC_BAD_ACCESS (0x28).
    //
    // `invalidate()` is called before the adapter is discarded so any in-flight or
    // late Go callback becomes a no-op. All Go callbacks are serialized onto a single
    // queue so invalidation and callback handling can't race.
    private let callbackQueue = DispatchQueue(label: "io.netbird.NetworkChangeListener")
    private var isValid = true

    private var tunnelManager: PacketTunnelProviderSettingsManager?

    var interfaceIP: String?
    var interfaceIPv6: String?

    init(with tunnelManager: PacketTunnelProviderSettingsManager) {
        self.tunnelManager = tunnelManager
    }

    /// Detach this listener from its tunnel manager. After this call every Go callback
    /// is dropped. Must be called before the owning adapter/provider is torn down.
    func invalidate() {
        callbackQueue.sync {
            self.isValid = false
            self.tunnelManager = nil
        }
    }

    func onNetworkChanged(_ p0: String?) {
        callbackQueue.sync {
            guard self.isValid, let tunnelManager = self.tunnelManager else {
                return
            }
            let routesString = p0 ?? ""
            let (v4Routes, v6Routes, containsDefault) = parseRoutesToNESettings(routesString: routesString)
            if v4Routes.isEmpty && v6Routes.isEmpty && self.interfaceIP == nil {
                return
            }
            tunnelManager.setRoutes(v4Routes: v4Routes, v6Routes: v6Routes, containsDefault: containsDefault)
        }
    }

    func setInterfaceIP(_ p0: String?) {
        callbackQueue.sync {
            guard self.isValid, let tunnelManager = self.tunnelManager else {
                return
            }
            guard let validIP = p0, !validIP.isEmpty else {
                return
            }
            self.interfaceIP = validIP
            tunnelManager.setInterfaceIP(interfaceIP: validIP)
        }
    }

    func setInterfaceIPv6(_ p0: String?) {
        callbackQueue.sync {
            guard self.isValid, let tunnelManager = self.tunnelManager else {
                return
            }
            guard let validIPv6 = p0, !validIPv6.isEmpty else {
                return
            }
            self.interfaceIPv6 = validIPv6
            tunnelManager.setInterfaceIPv6(interfaceIPv6: validIPv6)
        }
    }
    
    func parseRoutesToNESettings(routesString: String) -> ([NEIPv4Route], [NEIPv6Route], Bool) {
        var v4Routes : [NEIPv4Route] = []
        var v6Routes : [NEIPv6Route] = []
        var containsDefault = false
        
        let routes = routesString.split(separator: ",")
        for route in routes {
            let routeString = String(route)
            switch detectIPAddressType(routeString) {
            case .ipv4:
                if let ipv4Route = createIPv4RouteFromCIDR(cidr: routeString) {
                    v4Routes.append(ipv4Route)
                    if route.contains("0.0.0.0/0") {
                        containsDefault = true
                    }
                }
            case .ipv6:
                if let ipv6Route = createIPv6RouteFromCIDR(cidr: routeString) {
                    v6Routes.append(ipv6Route)
                    if route.contains("::/0") {
                        containsDefault = true
                    }
                }
            case .invalid:
                print("Unknown route: \(routeString)")
            }
        }
        
        if let interfaceIP = self.interfaceIP, let interfaceRoute = createIPv4RouteFromCIDR(cidr: interfaceIP) {
            v4Routes.append(interfaceRoute)
        }
        if let interfaceIPv6 = self.interfaceIPv6, let interfaceRoute = createIPv6RouteFromCIDR(cidr: interfaceIPv6) {
            v6Routes.append(interfaceRoute)
        }
        return (v4Routes, v6Routes, containsDefault)
    }
    
    func createIPv4RouteFromCIDR(cidr: String) -> NEIPv4Route? {
        guard let (ipAddress, subnetMask) = extractIPAddressAndSubnet(from: cidr),
              let destinationAddress = subtractSubnetMask(from: ipAddress, subnetMask: subnetMask) else {
            print("Failed to create IPv4 route for CIDR: \(cidr)")
            return nil
        }
        
        return NEIPv4Route(destinationAddress: destinationAddress, subnetMask: subnetMask)
    }
    
    func createIPv6RouteFromCIDR(cidr: String) -> NEIPv6Route? {
        let routeComponents = cidr.components(separatedBy: "/")
        guard routeComponents.count == 2,
              let destinationAddress = routeComponents.first,
              let prefixLength = Int(routeComponents[1]) else {
            print("Failed to create IPv6 route for CIDR: \(cidr)")
            return nil
        }
        
        return NEIPv6Route(destinationAddress: destinationAddress, networkPrefixLength: NSNumber(value: prefixLength))
    }
}

func detectIPAddressType(_ address: String) -> IPAddressType {
    let bare = address.split(separator: "/").first.map(String.init) ?? address

    var v4 = in_addr()
    if bare.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
        return .ipv4
    }
    var v6 = in6_addr()
    if bare.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 {
        return .ipv6
    }
    return .invalid
}

func extractIPAddressAndSubnet(from cidr: String) -> (String, String)? {
    let components = cidr.components(separatedBy: "/")
    
    guard components.count == 2,
          let ipAddress = components.first,
          var subnetPrefix = Int(components[1]),
          subnetPrefix >= 0 && subnetPrefix <= 32 else {
        return nil
    }
    
    var subnetMask = ""
    for i in 0..<4 {
        let bits = min(subnetPrefix, 8)
        let octet = 255 & (255 << (8 - bits))
        subnetMask += "\(octet)"
        if i < 3 {
            subnetMask += "."
        }
        subnetPrefix -= bits
    }
    
    return (ipAddress, subnetMask)
}

func subtractSubnetMask(from ipAddress: String, subnetMask: String) -> String? {
    let ipAddressComponents = ipAddress.split(separator: ".").compactMap { UInt32($0) }
    let subnetMaskComponents = subnetMask.split(separator: ".").compactMap { UInt32($0) }
    
    guard ipAddressComponents.count == 4 && subnetMaskComponents.count == 4 else {
        return nil
    }
    
    let networkAddressComponents = zip(ipAddressComponents, subnetMaskComponents).map { $0 & $1 }
    
    let networkAddress = networkAddressComponents.map { String($0) }.joined(separator: ".")
    
    return networkAddress
}
