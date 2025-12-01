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
    
    @Published var isOperationSuccessful: Bool = false
    @Published var isUiEnabled: Bool = true
    
    @Published var viewErrors = ServerViewErrors()
    private var cancellables = Set<AnyCancellable>()
    
    init(configurationFilePath: String, deviceName: String) {
        self.configurationFilePath = configurationFilePath
        self.deviceName = deviceName
        
        // Forward viewErrors changes to trigger ServerViewModel's objectWillChange
        // This is to make ServerViewModel react to changes made on ServerViewErrors.
        viewErrors.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
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
    
    private func handleSdkErrorMessage(errorMessage: String) {
        let reviewUrl = "Review the URL:\n\(errorMessage)"
        let reviewSetupKey = "Review the setup key:\n\(errorMessage)"
        
        if errorMessage.localizedCaseInsensitiveContains("dial context: context deadline exceeded") {
            viewErrors.urlError = reviewUrl
        } else if errorMessage.localizedCaseInsensitiveContains("failed while getting management service public key") {
            viewErrors.urlError = reviewUrl
        } else if errorMessage.localizedCaseInsensitiveContains("couldn't add peer: setup key is invalid") {
            viewErrors.setupKeyError = reviewSetupKey
        } else {
            // generic error
            viewErrors.generalError = errorMessage
        }
    }
    
    private func getAuthenticator(url managementServerUrl: String) async -> NetBirdSDKAuth? {
        let configPath = self.configurationFilePath
        let detachedTask = Task.detached(priority: .background) {
            var error: NSError?
            var errorMessage : String?
            var authenticator : NetBirdSDKAuth?
            authenticator = NetBirdSDKNewAuth(configPath, managementServerUrl, &error)
            
            if let error = error {
                print(error.domain, error.code, error.description)
                errorMessage = error.description
                authenticator = nil
                return (authenticator, errorMessage)
            }
            
            return (authenticator, nil)
        }
        
        let (authenticator, errorMessage) = await detachedTask.value
        
        if let errorMessage = errorMessage {
            handleSdkErrorMessage(errorMessage: errorMessage)
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
        
        if isUrlInvalid {
            viewErrors.urlError = "Invalid URL format"
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
            
            guard let auth = authenticator else {
                errorMessage = "Authentication not available"
                return (false, true, errorMessage)
            }
            
            do {
                var isSsoSupportedPointer: ObjCBool = false
                try auth.saveConfigIfSSOSupported(&isSsoSupportedPointer)
                
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
        } else {
            isUiEnabled = true
            
            if !isSsoSupported {
                viewErrors.ssoNotSupportedError = "SSO isn't available for the provided server, register this device with a setup key"
            } else if let error = errorMessage {
                handleSdkErrorMessage(errorMessage: error)
            }
        }
    }
    
    func loginWithSetupKey(managementServerUrl: String, setupKey: String) async {
        // disable UI here
        isUiEnabled = false
        await Task.yield()
        
        let isSetupKeyInvalid = isSetupKeyInvalid(setupKey: setupKey)
        let isUrlInvalid = isUrlInvalid(url: managementServerUrl)
        
        if isUrlInvalid {
            viewErrors.urlError = "Invalid URL format"
        }
        
        if isSetupKeyInvalid {
            viewErrors.setupKeyError = "Invalid setup key format"
        }
        
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
        
        let deviceName = self.deviceName
        let detachedTask = Task.detached {
            var isOperationSuccessful = false
            var errorMessage : String?
            
            guard let auth = authenticator else {
                errorMessage = "Authentication not available"
                return (false, errorMessage)
            }

            do {
                try auth.login(withSetupKeyAndSaveConfig: setupKey, deviceName: deviceName)
                isOperationSuccessful = true
            } catch {
                errorMessage = error.localizedDescription
            }
            
            return (isOperationSuccessful, errorMessage)
        }
        
        let (success, errorMessage) = await detachedTask.value
        
        if success {
            self.isOperationSuccessful = true
        } else {
            isUiEnabled = true
            
            if let error = errorMessage {
                handleSdkErrorMessage(errorMessage: error)
            }
        }
    }
    
    func clearErrorsFor(field: Field) {
        switch field {
        case .url:
            viewErrors.urlError = nil
            viewErrors.generalError = nil
            viewErrors.ssoNotSupportedError = nil
        case .setupKey:
            viewErrors.setupKeyError = nil
        case .all:
            clearErrorsFor(field: .url)
            clearErrorsFor(field: .setupKey)
        }
    }
}

enum Field {
    case url
    case setupKey
    case all
}

class ServerViewErrors : ObservableObject {
    @Published var urlError: String?
    @Published var setupKeyError: String?
    @Published var ssoNotSupportedError: String?
    @Published var generalError: String?
}
