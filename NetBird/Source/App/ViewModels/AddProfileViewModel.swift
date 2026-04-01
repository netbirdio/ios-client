//
//  AddProfileViewModel.swift
//  NetBird
//

import Foundation

#if os(iOS)

@MainActor
class AddProfileViewModel: ObservableObject {
    @Published var isLoading = false
    @Published var isSuccess = false
    @Published var profileError: String?
    @Published var urlError: String?
    @Published var setupKeyError: String?
    @Published var generalError: String?
    @Published var ssoNotSupportedError: String?

    private let defaultManagementServerUrl = "https://api.netbird.io"

    func create(name: String, serverUrl: String, setupKey: String) {
        clearErrors()

        // 1. Create profile directory
        do {
            try ProfileManager.shared.addProfile(name)
        } catch {
            profileError = error.localizedDescription
            return
        }

        // 2. Get config path for the new profile
        guard let configPath = ProfileManager.shared.configPath(for: name) else {
            profileError = "Unable to access profile directory"
            try? ProfileManager.shared.removeProfile(name)
            return
        }

        // 3. Configure the management server for this profile
        let serverVM = ServerViewModel(configurationFilePath: configPath, deviceName: Device.getName())
        let trimmedUrl = serverUrl.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let finalUrl = trimmedUrl.isEmpty ? defaultManagementServerUrl : trimmedUrl
        let key = setupKey.trimmingCharacters(in: .whitespacesAndNewlines)

        isLoading = true

        Task {
            if !key.isEmpty {
                await serverVM.loginWithSetupKey(managementServerUrl: finalUrl, setupKey: key)
            } else {
                await serverVM.changeManagementServerAddress(managementServerUrl: finalUrl)
            }

            isLoading = false

            if serverVM.isOperationSuccessful {
                isSuccess = true
            } else {
                // Surface errors and rollback profile creation
                urlError = serverVM.viewErrors.urlError
                setupKeyError = serverVM.viewErrors.setupKeyError
                generalError = serverVM.viewErrors.generalError
                ssoNotSupportedError = serverVM.viewErrors.ssoNotSupportedError
                try? ProfileManager.shared.removeProfile(name)
            }
        }
    }

    func clearErrors() {
        profileError = nil
        urlError = nil
        setupKeyError = nil
        generalError = nil
        ssoNotSupportedError = nil
    }
}

#endif
