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
    @Published var isSetupKeyInvalidFlag: Bool = false
    @Published var isUrlInvalidFlag: Bool = false
    
    init(configurationFilePath: String, deviceName: String) {
        self.configurationFilePath = configurationFilePath
        self.deviceName = deviceName
    }
    
    private func isSetupKeyInvalid(setupKey: String) -> Bool {
        if setupKey.isEmpty || setupKey.count != 36 {
            return true
        }
        
        let uuid = UUID(uuidString: setupKey)
        
        if uuid == nil {
            return true
        }
        
        return false
    }
    
    private func isUrlInvalid(url: String) -> Bool {
        if let url = URL(string: url), url.host != nil, url.scheme == "https" {
            return false
        } else {
            return true
        }
    }
    
    private func getAuthenticator(url managementServerUrl: String) async -> NetBirdSDKAuth? {
        var error: NSError?
        
        let authenticator = NetBirdSDKNewAuth(configurationFilePath, managementServerUrl, &error)
        
        if error != nil {
            print(error!.domain, error!.code, error!.description)
            errorMessage = error!.description
            return nil
        }
        
        return authenticator
    }
    
    func changeManagementServerAddress(managementServerUrl: String) async {
        let isUrlInvalid = isUrlInvalid(url: managementServerUrl)
        
        self.isUrlInvalidFlag = isUrlInvalid
        
        if isUrlInvalid {
            return
        }
        
        let authenticator = await getAuthenticator(url: managementServerUrl)
        
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
    
    func loginWithSetupKey(managementServerUrl: String, setupKey: String) async {
        let isSetupKeyInvalid = isSetupKeyInvalid(setupKey: setupKey)
        let isUrlInvalid = isUrlInvalid(url: managementServerUrl)
        
        self.isSetupKeyInvalidFlag = isSetupKeyInvalid
        self.isUrlInvalidFlag = isUrlInvalid
        
        if isSetupKeyInvalid || isUrlInvalid {
            return
        }
        
        let authenticator = await getAuthenticator(url: managementServerUrl)
        
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
