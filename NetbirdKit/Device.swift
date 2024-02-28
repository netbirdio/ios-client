//
//  Device.swift
//  GoLibTest
//
//  Created by Volodymyr Nazarkevych on 28.06.2023.
//

import UIKit

class Device {
    static func getName() -> String {
        return UIDevice.current.name
    }
    
    static func getOsVersion() -> String {
        return UIDevice.current.systemVersion
    }
    
    static func getOsName() -> String {
        return UIDevice.current.systemName
    }
}
