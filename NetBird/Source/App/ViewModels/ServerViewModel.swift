//
//  ServerViewModel.swift
//  NetBird
//
//  Created by Diego Romar on 24/11/25.
//

import Combine

@MainActor
class ServerViewModel : ObservableObject {
    let configurationFilePath: String
    let deviceName: String
    
    @Published var errorMessage: String?
    @Published var isOperationSuccessful: Bool = false
    @Published var isSsoSupported: Bool?
    
    init(configurationFilePath: String, deviceName: String) {
        self.configurationFilePath = configurationFilePath
        self.deviceName = deviceName
    }
    
    private func getAuthenticator(url managementServerUrl: String) -> NetBirdSDKAuth? {
        var error: NSError?
        let authenticator = NetBirdSDKNewAuth(configurationFilePath, managementServerUrl, &error)
        
        if error != nil {
            print(error!.domain, error!.code, error!.description)
            errorMessage = error!.description
            return nil
        }
        
        return authenticator
    }
    
    func changeManagementServerAddress(managementServerUrl: String) {
        let authenticator = getAuthenticator(url: managementServerUrl)
        
        var isSsoSupported: ObjCBool = false
        
        do {
            try authenticator?.saveConfigIfSSOSupported(&isSsoSupported)
            
            if isSsoSupported.boolValue {
                //emit success state
                isOperationSuccessful = true
            } else {
                self.isSsoSupported = false
            }
        } catch {
            errorMessage = error.localizedDescription
            return
        }
    }
    
    func loginWithSetupKey(managementServerUrl: String, setupKey: String) {
        let authenticator = getAuthenticator(url: managementServerUrl)
        
        do {
            try authenticator?.login(withSetupKeyAndSaveConfig: setupKey, deviceName: self.deviceName)
            //emit success state
            isOperationSuccessful = true
        } catch {
            errorMessage = error.localizedDescription
            return
        }
    }
}
