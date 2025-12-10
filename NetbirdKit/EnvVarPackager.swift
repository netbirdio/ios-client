//
//  EnvVarPackager.swift
//  NetBird
//
//  Created by Diego Romar on 03/12/25.
//

class EnvVarPackager {
    static func getEnvironmentVariables(defaults: UserDefaults) -> NetBirdSDKEnvList? {
        guard let envList = NetBirdSDKEnvList() else {
            return nil
        }
        
        defaults.register(defaults: [GlobalConstants.keyForceRelayConnection: true])
        let forceRelayConnection = defaults.bool(forKey: GlobalConstants.keyForceRelayConnection)
        
        envList.put(NetBirdSDKGetEnvKeyNBForceRelay(), value: String(forceRelayConnection))
        
        return envList
    }
}
