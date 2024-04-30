//
//  MainViewModel.swift
//  NetBirdiOS
//
//  Created by Pascal Fischer on 01.08.23.
//

import UIKit
import NetworkExtension
import os
import Combine

@MainActor
class ViewModel: ObservableObject {    
    @Published var networkExtensionAdapter = NetworkExtensionAdapter()
    @Published var showSetupKeyPopup = false
    @Published var showChangeServerAlert = false
    @Published var showInvalidServerAlert = false
    @Published var showInvalidSetupKeyHint = false
    @Published var showInvalidSetupKeyAlert = false
    @Published var showLogLevelChangedAlert = false
    @Published var showInvalidPresharedKeyAlert = false
    @Published var showServerChangedInfo = false
    @Published var showPreSharedKeyChangedInfo = false
    @Published var showCopiedAlert = false
    @Published var showCopiedInfoAlert = false
    @Published var showAuthenticationRequired = false
    @Published var presentSideDrawer = false
    @Published var extensionState : NEVPNStatus = .disconnected
    @Published var navigateToServerView = false
    @Published var rosenpassEnabled = false
    @Published var rosenpassPermissive = false
    @Published var managementURL = ""
    @Published var presharedKey = ""
    @Published var server: String = ""
    @Published var setupKey: String = ""
    @Published var presharedKeySecure = true
    @Published var statusDetails = StatusDetails(ip: "", fqdn: "", managementStatus: .disconnected, peerInfo: [])
    @Published var statusDetailsValid = false
    @Published var extensionStateText = "Disconnected"
    @Published var connectPressed = false
    @Published var disconnectPressed = false
    @Published var traceLogsEnabled: Bool {
        didSet {
            self.showLogLevelChangedAlert = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                self.showLogLevelChangedAlert = false
            }
            let logLevel = traceLogsEnabled ? "TRACE" : "INFO"
            UserDefaults.standard.set(logLevel, forKey: "logLevel")
            UserDefaults.standard.synchronize()
        }
    }
    var preferences = Preferences.newPreferences()
    var buttonLock = false
    let defaults = UserDefaults.standard
    @Published var fqdn = UserDefaults.standard.string(forKey: "fqdn") ?? ""
    @Published var ip = UserDefaults.standard.string(forKey: "ip") ?? ""
    
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        let logLevel = UserDefaults.standard.string(forKey: "logLevel") ?? "INFO"
        self.traceLogsEnabled = logLevel == "TRACE"
        self.rosenpassEnabled = self.getRosenpassEnabled()
        self.rosenpassPermissive = self.getRosenpassPermissive()
        
        $server
           .removeDuplicates()
           .debounce(for: .seconds(0.5), scheduler: RunLoop.main)
           .map { server in
               !self.isValidURL(server)
           }
           .assign(to: &$showInvalidServerAlert)

       $setupKey
           .removeDuplicates()
           .debounce(for: .seconds(0.5), scheduler: RunLoop.main)
           .map { setupKey in
               !self.isValidSetupKey(setupKey)
           }
           .assign(to: &$showInvalidSetupKeyHint)
    }
    
    func connect()  {
        self.connectPressed = true
        print("Connected pressed set to true")
        DispatchQueue.main.async {
            print("starting extension")
            self.buttonLock = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                self.buttonLock = false
            }
            Task {
                await self.networkExtensionAdapter.start()
                print("Connected pressed set to false")
            }
        }
    }
    
    func close() -> Void {
        self.disconnectPressed = true
        DispatchQueue.main.async {
            print("Stopping extension")
            self.buttonLock = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                self.buttonLock = false
            }
            self.networkExtensionAdapter.stop()
        }
    }
    
    func startPollingDetails() {
        networkExtensionAdapter.startTimer { details in
            let sortedPeerInfo = details.peerInfo.sorted(by: { a, b in
                a.ip < b.ip
            })
            
            self.checkExtensionState()
            if self.extensionState == .disconnected && self.extensionStateText == "Connected" {
                self.showAuthenticationRequired = true
                self.extensionStateText = "Disconnected"
            }
            
            let newStatusDetails = StatusDetails(ip: details.ip, fqdn: details.fqdn, managementStatus: details.managementStatus, peerInfo: sortedPeerInfo)
            if newStatusDetails.ip != self.statusDetails.ip || newStatusDetails.fqdn != self.statusDetails.fqdn || newStatusDetails.managementStatus != self.statusDetails.managementStatus || !newStatusDetails.peerInfo.elementsEqual(self.statusDetails.peerInfo, by: { a, b in
                a.ip == b.ip && a.connStatus == b.connStatus
            }) {
                if !newStatusDetails.fqdn.isEmpty && newStatusDetails.fqdn != self.statusDetails.fqdn {
                    self.defaults.set(newStatusDetails.fqdn, forKey: "fqdn")
                    self.fqdn = details.fqdn

                }
                if !newStatusDetails.ip.isEmpty && newStatusDetails.ip != self.statusDetails.ip {
                    self.defaults.set(newStatusDetails.ip, forKey: "ip")
                    self.ip = details.ip
                }

                print("Status: \(newStatusDetails.managementStatus) - Extension: \(self.extensionState) - LoginRequired: \(self.networkExtensionAdapter.isLoginRequired())")
                if newStatusDetails.managementStatus == .disconnected && self.extensionState == .connected && self.networkExtensionAdapter.isLoginRequired() {
                    self.networkExtensionAdapter.stop()
                    self.showAuthenticationRequired = true
                }
                self.statusDetails = newStatusDetails
            }
            self.statusDetailsValid = true
        }
    }
    
    func stopPollingDetails() {
        networkExtensionAdapter.stopTimer()
    }
    
    func checkExtensionState() {
        networkExtensionAdapter.getExtensionStatus { status in
            let statuses : [NEVPNStatus] = [.connected, .disconnected, .connecting, .disconnecting]
            DispatchQueue.main.async {
                if statuses.contains(status) && self.extensionState != status {
                    print("Changing extension status")
                    self.extensionState = status
                }
            }
        }
    }
    
    func updateManagementURL(url: String) -> Bool? {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let newAuth = NetBirdSDKNewAuth(Preferences.configFile(), trimmedURL, nil)
        self.managementURL = trimmedURL
        var ssoSupported: ObjCBool = false
        do {
            try newAuth?.saveConfigIfSSOSupported(&ssoSupported)
            if ssoSupported.boolValue {
                print("SSO is supported")
                return true
            } else {
                print("SSO is not supported. Fallback to setup key")
                return false
            }
        } catch {
            print("Failed to check SSO support")
        }
        return nil
    }
    
    func clearDetails() {
        self.ip = ""
        self.fqdn = ""
        defaults.removeObject(forKey: "ip")
        defaults.removeObject(forKey: "fqdn")
    }
    
    func setSetupKey(key: String) throws {
        let newAuth = NetBirdSDKNewAuth(Preferences.configFile(), self.managementURL, nil)
        try newAuth?.login(withSetupKeyAndSaveConfig: key, deviceName: Device.getName())
        self.managementURL = ""
    }
    
    func updatePreSharedKey() {
        preferences.setPreSharedKey(presharedKey)
        do {
            try preferences.commit()
            self.close()
            self.presharedKeySecure = true
            self.presentSideDrawer = false
            self.showPreSharedKeyChangedInfo = true
        } catch {
            print("Failed to update preshared key")
        }
    }
    
    func removePreSharedKey() {
        presharedKey = ""
        preferences.setPreSharedKey(presharedKey)
        do {
            try preferences.commit()
            self.close()
            self.presharedKeySecure = false
        } catch {
            print("Failed to remove preshared key")
        }
    }
    
    func loadPreSharedKey() {
        self.presharedKey = preferences.getPreSharedKey(nil)
        self.presharedKeySecure = self.presharedKey != ""
    }
    
    func setRosenpassEnabled(enabled: Bool) {
        preferences.setRosenpassEnabled(enabled)
        do {
            try preferences.commit()
        } catch {
            print("Failed to update rosenpass settings")
        }
    }
    
    func getRosenpassEnabled() -> Bool {
        var result = ObjCBool(false)
        do {
            try preferences.getRosenpassEnabled(&result)
        } catch {
            print("Failed to read rosenpass settings")
        }
    
        return result.boolValue
    }

    
    func getRosenpassPermissive() -> Bool {
        var result = ObjCBool(false)
        do {
            try preferences.getRosenpassPermissive(&result)
        } catch {
            print("Failed to read rosenpass permissive settings")
        }
    
        return result.boolValue
    }

    
    func setRosenpassPermissive(permissive: Bool) {
        preferences.setRosenpassPermissive(permissive)
        do {
            try preferences.commit()
        } catch {
            print("Failed to update rosenpass permissive settings")
        }
    }
    
    func getDefaultStatus() -> StatusDetails {
        return StatusDetails(ip: "", fqdn: "", managementStatus: .disconnected, peerInfo: [])
    }
    
    func isValidURL(_ string: String) -> Bool {
        let trimmedString = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedString.isEmpty { return true }
        
        let pattern = "^(?i)https?://(([a-zA-Z\\d]([a-zA-Z\\d-]{0,61}[a-zA-Z\\d])?\\.)*[a-zA-Z]{2,})(?::\\d{1,5})?(?:/|$)"

        let isMatch = trimmedString.range(of: pattern, options: .regularExpression, range: nil, locale: nil) != nil
        return isMatch
    }
    
    func isValidSetupKey(_ string: String) -> Bool {
        if string.isEmpty { return true }
        let pattern = "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
        let isMatch = string.range(of: pattern, options: .regularExpression, range: nil, locale: nil) != nil
        return isMatch
    }
}

func printLogContents(from logURL: URL) {
    do {
        let logContents = try String(contentsOf: logURL, encoding: .utf8)
        print(logContents)
    } catch {
        print("Failed to read the log file: \(error.localizedDescription)")
    }
}
