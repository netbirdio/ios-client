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
        return NetBirdSDKNewPreferences(configFile(), stateFile())!
    }

    static func configFile() -> String {
        let fileManager = FileManager.default
        let groupURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: "group.io.netbird.app")
        let logURL = groupURL?.appendingPathComponent("netbird.cfg")
        return logURL!.relativePath
    }
    
    static func stateFile() -> String {
        let fileManager = FileManager.default
        let groupURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: "group.io.netbird.app")
        let logURL = groupURL?.appendingPathComponent("state.json")
        return logURL!.relativePath
    }
    
}
