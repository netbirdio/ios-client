//
//  EnvVarPackager.swift
//  NetBird
//
//  Created by Diego Romar on 03/12/25.
//

import Foundation
import NetBirdSDK

class EnvVarPackager {
    static func getEnvironmentVariables(defaults: UserDefaults) -> NetBirdSDKEnvList? {
        guard let envList = NetBirdSDKEnvList() else {
            return nil
        }

        #if os(iOS)
        let defaultForceRelay = true
        #else
        // Forced relay battery optimization not needed on Apple TV
        let defaultForceRelay = false
        #endif

        defaults.register(defaults: [GlobalConstants.keyForceRelayConnection: defaultForceRelay])
        let forceRelayConnection = defaults.bool(forKey: GlobalConstants.keyForceRelayConnection)

        let defaultLazyConnection = true
        defaults.register(defaults: [GlobalConstants.keyEnableLazyConnection: defaultLazyConnection])
        let isLazyConnectionEnabled = defaults.bool(forKey: GlobalConstants.keyEnableLazyConnection)
        
        envList.put(NetBirdSDKGetEnvKeyNBForceRelay(), value: String(forceRelayConnection))
        envList.put(NetBirdSDKGetEnvKeyNBLazyConn(), value: String(isLazyConnectionEnabled))
        envList.put(NetBirdSDKGetEnvKeyNBInactivityThreshold(), value: String(5))
        
        return envList
    }
}
