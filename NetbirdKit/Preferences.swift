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

    static func getFilePath(fileName: String) -> String {
        let fileManager = FileManager.default
        if let groupURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: GlobalConstants.userPreferencesSuiteName) {
            return groupURL.appendingPathComponent(fileName).relativePath
        }
        
        // Fallback for testing or when app group is not available
        // (prefer non-user-visible dir)
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
        return (baseURL ?? fileManager.temporaryDirectory).appendingPathComponent(fileName).path
    }
    
    static func configFile() -> String {
        return getFilePath(fileName: GlobalConstants.configFileName)
    }
    
    static func stateFile() -> String {
        return getFilePath(fileName: GlobalConstants.stateFileName)
    }
    
}
