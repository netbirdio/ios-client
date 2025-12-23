//
//  Device.swift
//  GoLibTest
//
//  Created by Volodymyr Nazarkevych on 28.06.2023.
//

import UIKit

class Device {
    static func getName() -> String {
        #if os(tvOS)
        return generateTVDeviceName()
        #else
        return UIDevice.current.name
        #endif
    }

    static func getOsVersion() -> String {
        return UIDevice.current.systemVersion
    }

    static func getOsName() -> String {
        return UIDevice.current.systemName
    }

    #if os(tvOS)
    /// Generate a unique device name for tvOS
    /// The name is persisted so it remains consistent across app launches
    private static func generateTVDeviceName() -> String {
        let key = "netbird_device_name"
        let appGroup = GlobalConstants.userPreferencesSuiteName

        // Return cached name if it exists
        if let defaults = UserDefaults(suiteName: appGroup),
           let cachedName = defaults.string(forKey: key), !cachedName.isEmpty {
            return cachedName
        }

        // Generate random 6-character alphanumeric string
        let characters = "abcdefghijklmnopqrstuvwxyz0123456789"
        let randomString = String((0..<6).map { _ in characters.randomElement()! })
        let name = "apple-tv-\(randomString)"

        // Cache the name for future use
        if let defaults = UserDefaults(suiteName: appGroup) {
            defaults.set(name, forKey: key)
            defaults.synchronize()
        }

        return name
    }
    #endif
}
