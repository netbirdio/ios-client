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
        
        var forceRelayConnection : Bool
        
        if defaults.object(forKey: GlobalConstants.keyForceRelayConnection) == nil {
            forceRelayConnection = true
        } else {
            forceRelayConnection = defaults.bool(forKey: GlobalConstants.keyForceRelayConnection)
        }
        
        envList.put(NetBirdSDKGetEnvKeyNBForceRelay(), value: String(forceRelayConnection))
        
        return envList
    }
}
