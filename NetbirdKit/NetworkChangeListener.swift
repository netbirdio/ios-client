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
    func onNetworkChanged(_ p0: String?) {
        if p0 == nil || p0!.isEmpty {
            return
        }
        let (v4Routes, v6Routes, containsDefault) = parseRoutesToNESettings(routesString: p0!)
        self.tunnelManager.setRoutes(v4Routes: v4Routes, v6Routes: v6Routes, containsDefault: containsDefault)
    }
    
    private var tunnelManager: PacketTunnelProviderSettingsManager
    
    var interfaceIP: String?
    
    init(with tunnelManager: PacketTunnelProviderSettingsManager) {
        self.tunnelManager = tunnelManager
    }
    
    func setInterfaceIP(_ p0: String?) {
        if p0 == nil || p0!.isEmpty {
            return
        }
        self.interfaceIP = p0!
        self.tunnelManager.setInterfaceIP(interfaceIP: p0!)
    }
    
    func parseRoutesToNESettings(routesString: String) -> ([NEIPv4Route], [NEIPv6Route], Bool) {
        var v4Routes : [NEIPv4Route] = []
        var v6Routes : [NEIPv6Route] = []
        var containsDefault = false
        
        let routes = routesString.split(separator: ",")
        for route in routes {
            switch detectIPAddressType(String(route)) {
            case .ipv4:
                v4Routes.append(createIPv4RouteFromCIDR(cidr: String(route)))
                if route.contains("0.0.0.0/0") {
                    containsDefault = true
                }
            case .ipv6:
                v6Routes.append(createIPv6RouteFromCIDR(cidr: String(route)))
                if route.contains("::/0") {
                    containsDefault = true
                }
            case .invalid:
                print("unknown route")
            }
        }
        
        if let interfaceIP = self.interfaceIP {
            v4Routes.append(createIPv4RouteFromCIDR(cidr: interfaceIP))
        }
        return (v4Routes, v6Routes, containsDefault)
    }
    
    func createIPv4RouteFromCIDR(cidr: String) -> NEIPv4Route {
        let (ipAddress, subnetMask) = extractIPAddressAndSubnet(from: cidr)!
        let destinationAddress = subtractSubnetMask(from: ipAddress, subnetMask: subnetMask)
        
        return NEIPv4Route(destinationAddress: destinationAddress!, subnetMask: subnetMask)
    }
    
    func createIPv6RouteFromCIDR(cidr: String) -> NEIPv6Route {
        let routeComponents = cidr.components(separatedBy: "/")
        let destinationAddress = routeComponents[0]
        let prefixLength = Int(routeComponents[1])!
        return NEIPv6Route(destinationAddress: destinationAddress, networkPrefixLength: prefixLength as NSNumber)
    }
    
}

func detectIPAddressType(_ address: String) -> IPAddressType {
    let ipv4Pattern = "^(\\d{1,3}\\.){3}\\d{1,3}(\\/\\d{1,2})?$"
    let ipv6Pattern = "^([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}(\\/\\d{1,3})?$"

    let ipv4Regex = try! NSRegularExpression(pattern: ipv4Pattern, options: [])
    let ipv6Regex = try! NSRegularExpression(pattern: ipv6Pattern, options: [])

    let ipv4Matches = ipv4Regex.numberOfMatches(in: address, options: [], range: NSRange(location: 0, length: address.utf16.count))
    let ipv6Matches = ipv6Regex.numberOfMatches(in: address, options: [], range: NSRange(location: 0, length: address.utf16.count))

    if ipv4Matches > 0 {
        return .ipv4
    } else if ipv6Matches > 0 {
        return .ipv6
    } else {
        return .invalid
    }
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
