//
//  ServerViewModel.swift
//  NetBird
//
//  Created by Diego Romar on 24/11/25.
//

import Combine
import NetBirdSDK

// MARK: - SDK Listener Implementations

/// Listener for SSO support check
class SSOListenerImpl: NSObject, NetBirdSDKSSOListenerProtocol {
    private let onSuccessHandler: (Bool) -> Void
    private let onErrorHandler: (Error) -> Void

    init(onSuccess: @escaping (Bool) -> Void, onError: @escaping (Error) -> Void) {
        self.onSuccessHandler = onSuccess
        self.onErrorHandler = onError
    }

    func onSuccess(_ ssoSupported: Bool) {
        onSuccessHandler(ssoSupported)
    }

    func onError(_ error: (any Error)?) {
        if let error = error {
            onErrorHandler(error)
        }
    }
}

/// Listener for login operations
class ErrListenerImpl: NSObject, NetBirdSDKErrListenerProtocol {
    private let onSuccessHandler: () -> Void
    private let onErrorHandler: (Error) -> Void

    init(onSuccess: @escaping () -> Void, onError: @escaping (Error) -> Void) {
        self.onSuccessHandler = onSuccess
        self.onErrorHandler = onError
    }

    func onSuccess() {
        onSuccessHandler()
    }

    func onError(_ error: (any Error)?) {
        if let error = error {
            onErrorHandler(error)
        }
    }
}

// MARK: - ServerViewModel

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
        let detachedTask = Task.detached(priority: .background) -> (NetBirdSDKAuth?, String?) in
            var error: NSError?
            let authenticator = NetBirdSDKNewAuth(configPath, managementServerUrl, &error)

            if let error = error {
                print(error.domain, error.code, error.description)
                return (authenticator, error.description)
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

        guard let authenticator = await getAuthenticator(url: managementServerUrl) else {
            isUiEnabled = true
            return
        }

        // Use continuation to bridge async callback to async/await
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let listener = SSOListenerImpl(
                onSuccess: { [weak self] ssoSupported in
                    Task { @MainActor in
                        if ssoSupported {
                            self?.isOperationSuccessful = true
                        } else {
                            self?.isUiEnabled = true
                            self?.viewErrors.ssoNotSupportedError = "SSO isn't available for the provided server, register this device with a setup key"
                        }
                        continuation.resume()
                    }
                },
                onError: { [weak self] error in
                    Task { @MainActor in
                        self?.isUiEnabled = true
                        self?.handleSdkErrorMessage(errorMessage: error.localizedDescription)
                        continuation.resume()
                    }
                }
            )

            authenticator.saveConfigIfSSOSupported(listener)
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

        guard let authenticator = await getAuthenticator(url: managementServerUrl) else {
            isUiEnabled = true
            return
        }

        let deviceName = self.deviceName

        // Use continuation to bridge async callback to async/await
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let listener = ErrListenerImpl(
                onSuccess: { [weak self] in
                    Task { @MainActor in
                        self?.isOperationSuccessful = true
                        continuation.resume()
                    }
                },
                onError: { [weak self] error in
                    Task { @MainActor in
                        self?.isUiEnabled = true
                        self?.handleSdkErrorMessage(errorMessage: error.localizedDescription)
                        continuation.resume()
                    }
                }
            )

            authenticator.login(withSetupKeyAndSaveConfig: listener, setupKey: setupKey, deviceName: deviceName)
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
