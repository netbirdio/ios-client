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
    @Published var isUiEnabled: Bool = true
    
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
        if let url = URL(string: url), url.host != nil {
            return false
        } else {
            return true
        }
    }
    
    private func getAuthenticator(url managementServerUrl: String) async -> NetBirdSDKAuth? {
        let detachedTask = Task.detached(priority: .background) {
            var error: NSError?
            var errorMessage : String?
            var authenticator : NetBirdSDKAuth?
            authenticator = NetBirdSDKNewAuth(self.configurationFilePath, managementServerUrl, &error)
            
            if error != nil {
                print(error!.domain, error!.code, error!.description)
                errorMessage = error!.description
                authenticator = nil
                return (authenticator, errorMessage)
            }
            
            return (authenticator, nil)
        }
        
        let (authenticator, errorMessage) = await detachedTask.value
        
        if errorMessage != nil {
            self.errorMessage = errorMessage
            return nil
        } else {
            return authenticator
        }
    }
    
    func changeManagementServerAddress(managementServerUrl: String) async {
        // disable UI here
        isUiEnabled = false
        await Task.yield()
        
        let isUrlInvalid = isUrlInvalid(url: managementServerUrl)
        
        self.isUrlInvalidFlag = isUrlInvalid
        
        if isUrlInvalid {
            // error state emitted, enable UI here
            isUiEnabled = true
            return
        }
        
        let authenticator = await getAuthenticator(url: managementServerUrl)
        if authenticator == nil {
            isUiEnabled = true
            return
        }
        
        let detachedTask = Task.detached {
            var isSsoSupported: Bool = true
            var isOperationSuccessful: Bool = false
            var errorMessage: String?
            
            do {
                var isSsoSupportedPointer: ObjCBool = false
                try authenticator!.saveConfigIfSSOSupported(&isSsoSupportedPointer)
                
                if isSsoSupportedPointer.boolValue {
                    isOperationSuccessful = true
                } else {
                    isSsoSupported = false
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            
            return (isOperationSuccessful, isSsoSupported, errorMessage)
        }
        
        let (success, isSsoSupported, errorMessage) = await detachedTask.value
        
        if success {
            self.isOperationSuccessful = true
        } else if !isSsoSupported {
            self.isSsoSupported = false
        } else if errorMessage != nil {
            self.errorMessage = errorMessage
            isUiEnabled = true
        }
    }
    
    func loginWithSetupKey(managementServerUrl: String, setupKey: String) async {
        // disable UI here
        isUiEnabled = false
        await Task.yield()
        
        let isSetupKeyInvalid = isSetupKeyInvalid(setupKey: setupKey)
        let isUrlInvalid = isUrlInvalid(url: managementServerUrl)
        
        self.isSetupKeyInvalidFlag = isSetupKeyInvalid
        self.isUrlInvalidFlag = isUrlInvalid
        
        if isSetupKeyInvalid || isUrlInvalid {
            // error states emitted, enable UI here
            isUiEnabled = true
            return
        }
        
        let authenticator = await getAuthenticator(url: managementServerUrl)
        if authenticator == nil {
            isUiEnabled = true
            return
        }
        
        let detachedTask = Task.detached {
            var isOperationSuccessful = false
            var errorMessage : String?

            do {
                try authenticator!.login(withSetupKeyAndSaveConfig: setupKey, deviceName: self.deviceName)
                isOperationSuccessful = true
            } catch {
                errorMessage = error.localizedDescription
            }
            
            return (isOperationSuccessful, errorMessage)
        }
        
        let (success, errorMessage) = await detachedTask.value
        
        if success {
            self.isOperationSuccessful = true
        } else if errorMessage != nil {
            self.errorMessage = errorMessage
            isUiEnabled = true
        }
        
//        do {
//            try authenticator!.login(withSetupKeyAndSaveConfig: setupKey, deviceName: self.deviceName)
//            //emit success state
//            isOperationSuccessful = true
//        } catch {
//            errorMessage = error.localizedDescription
//            // error states emitted, enable UI here
//            isUiEnabled = true
//        }
    }
}
