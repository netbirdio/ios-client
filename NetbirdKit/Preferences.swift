//
//  Preferences.swift
//  NetBirdiOS
//
//  Created by Pascal Fischer on 03.08.23.
//

import Foundation
import NetBirdSDK

class Preferences {
    static func newPreferences() -> NetBirdSDKPreferences {
        guard let prefs = NetBirdSDKNewPreferences(configFile(), stateFile()) else {
            preconditionFailure("Failed to create NetBirdSDKPreferences")
        }
        return prefs
    }

    static func configFile() -> String {
        let fileManager = FileManager.default
        if let groupURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: "group.io.netbird.app") {
            return groupURL.appendingPathComponent("netbird.cfg").relativePath
        }
        // Fallback for testing or when app group is not available
        let documentsPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first!
        return (documentsPath as NSString).appendingPathComponent("netbird.cfg")
    }
    
    static func stateFile() -> String {
        let fileManager = FileManager.default
        if let groupURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: "group.io.netbird.app") {
            return groupURL.appendingPathComponent("state.json").relativePath
        }
        // Fallback for testing or when app group is not available
        let documentsPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first!
        return (documentsPath as NSString).appendingPathComponent("state.json")
    }
    
}
