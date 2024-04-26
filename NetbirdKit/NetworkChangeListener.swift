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


class NetworkChangeListener: NSObject, NetBirdSDKNetworkChangeListenerProtocol {
    func onNetworkChanged(_ p0: String?) {
        let routes = parseRoutesToNESettings(routesString: p0!)
        tunnelManager?.setRoutes(routes: routes)
    }
    
    private weak var tunnelManager: PacketTunnelProviderSettingsManager?
    
    var interfaceIP: String?
    
    init(with tunnelManager: PacketTunnelProviderSettingsManager) {
        self.tunnelManager = tunnelManager
    }
    
    func setInterfaceIP(_ p0: String?) {
        self.interfaceIP = p0!
        tunnelManager?.setInterfaceIP(interfaceIP: p0!)
    }
    
    func parseRoutesToNESettings(routesString: String) -> [NEIPv4Route] {
        var neRoutes : [NEIPv4Route] = []
        
        let routes = routesString.split(separator: ",")
        for route in routes {
            if route.contains("0.0.0.0/0") {
                neRoutes.append(createIPv4RouteFromCIDR(cidr: "0.0.0.1/32"))
                neRoutes.append(createIPv4RouteFromCIDR(cidr: "0.0.0.2/31"))
                neRoutes.append(createIPv4RouteFromCIDR(cidr: "0.0.0.4/30"))
                neRoutes.append(createIPv4RouteFromCIDR(cidr: "0.0.0.8/29"))
                neRoutes.append(createIPv4RouteFromCIDR(cidr: "0.0.0.16/28"))
                neRoutes.append(createIPv4RouteFromCIDR(cidr: "0.0.0.32/27"))
                neRoutes.append(createIPv4RouteFromCIDR(cidr: "0.0.0.64/26"))
                neRoutes.append(createIPv4RouteFromCIDR(cidr: "0.0.0.128/25"))
                neRoutes.append(createIPv4RouteFromCIDR(cidr: "0.0.1.0/24"))
                neRoutes.append(createIPv4RouteFromCIDR(cidr: "0.0.2.0/23"))
                neRoutes.append(createIPv4RouteFromCIDR(cidr: "0.0.4.0/22"))
                neRoutes.append(createIPv4RouteFromCIDR(cidr: "0.0.8.0/21"))
                neRoutes.append(createIPv4RouteFromCIDR(cidr: "0.0.16.0/20"))
                neRoutes.append(createIPv4RouteFromCIDR(cidr: "0.0.32.0/19"))
                neRoutes.append(createIPv4RouteFromCIDR(cidr: "0.0.64.0/18"))
                neRoutes.append(createIPv4RouteFromCIDR(cidr: "0.0.128.0/17"))
                neRoutes.append(createIPv4RouteFromCIDR(cidr: "0.1.0.0/16"))
                neRoutes.append(createIPv4RouteFromCIDR(cidr: "0.2.0.0/15"))
                neRoutes.append(createIPv4RouteFromCIDR(cidr: "0.4.0.0/14"))
                neRoutes.append(createIPv4RouteFromCIDR(cidr: "0.8.0.0/13"))
                neRoutes.append(createIPv4RouteFromCIDR(cidr: "0.16.0.0/12"))
                neRoutes.append(createIPv4RouteFromCIDR(cidr: "0.32.0.0/11"))
                neRoutes.append(createIPv4RouteFromCIDR(cidr: "0.64.0.0/10"))
                neRoutes.append(createIPv4RouteFromCIDR(cidr: "0.128.0.0/9"))
                neRoutes.append(createIPv4RouteFromCIDR(cidr: "1.0.0.0/8"))
                neRoutes.append(createIPv4RouteFromCIDR(cidr: "2.0.0.0/7"))
                neRoutes.append(createIPv4RouteFromCIDR(cidr: "4.0.0.0/6"))
                neRoutes.append(createIPv4RouteFromCIDR(cidr: "8.0.0.0/5"))
                neRoutes.append(createIPv4RouteFromCIDR(cidr: "16.0.0.0/4"))
                neRoutes.append(createIPv4RouteFromCIDR(cidr: "32.0.0.0/3"))
                neRoutes.append(createIPv4RouteFromCIDR(cidr: "64.0.0.0/2"))
                neRoutes.append(createIPv4RouteFromCIDR(cidr: "128.0.0.0/1"))
            } else {
                neRoutes.append(createIPv4RouteFromCIDR(cidr: String(route)))
            }
        }
        if interfaceIP != nil {
            neRoutes.append(createIPv4RouteFromCIDR(cidr: self.interfaceIP!))
        }
        return neRoutes
    }
    
    func createIPv4RouteFromCIDR(cidr: String) -> NEIPv4Route {
        let (ipAddress, subnetMask) = extractIPAddressAndSubnet(from: cidr)!
        let destinationAddress = subtractSubnetMask(from: ipAddress, subnetMask: subnetMask)
        return NEIPv4Route(destinationAddress: destinationAddress!, subnetMask: subnetMask)
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
