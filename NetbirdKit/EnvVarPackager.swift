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

        // P2P connections are more efficient than relay for both performance
        // and battery life. The previous default of true was a workaround for
        // ICE stability issues that have since been fixed upstream.
        let defaultForceRelay = false

        defaults.register(defaults: [GlobalConstants.keyForceRelayConnection: defaultForceRelay])
        let forceRelayConnection = defaults.bool(forKey: GlobalConstants.keyForceRelayConnection)

        envList.put(NetBirdSDKGetEnvKeyNBForceRelay(), value: String(forceRelayConnection))

        return envList
    }
}
