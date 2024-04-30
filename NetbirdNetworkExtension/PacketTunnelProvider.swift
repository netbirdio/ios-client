//
//  PacketTunnelProvider.swift
//  NetbirdNetworkExtension
//
//  Created by Pascal Fischer on 06.08.23.
//

import NetworkExtension
import os
import Firebase
import FirebaseCrashlytics
import FirebaseCore
import FirebasePerformance


class PacketTunnelProvider: NEPacketTunnelProvider {
    
    private lazy var tunnelManager: PacketTunnelProviderSettingsManager = {
        return PacketTunnelProviderSettingsManager(with: self)
    }()
    
    private lazy var adapter: NetBirdAdapter = {
        return NetBirdAdapter(with: self.tunnelManager)
    }()
            
    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let firebaseOptions = FirebaseOptions(contentsOfFile: Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist")!)
        FirebaseApp.configure(options: firebaseOptions!)
        
        if let options = options {
            // For example, handle a specific option
            if let logLevel = options["logLevel"] as? String {
                initializeLogging(loglevel: logLevel)
            }
        }
        
        
        if adapter.needsLogin() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                completionHandler(NSError(domain: "io.netbird.NetbirdNetworkExtension", code: 1001, userInfo: [NSLocalizedDescriptionKey: "Login required."]))
            }
            return
        }
                
        adapter.start(completionHandler: completionHandler)
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        adapter.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            completionHandler()
        }
    }
    
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let completionHandler = completionHandler else { return }
        
        if let string = String(data: messageData, encoding: .utf8) {
            switch string {
            case "Login":
                login(completionHandler: completionHandler)
            case "Status":
                getStatus(completionHandler: completionHandler)
            default:
                print("unknown message")
            }
        }
    }
    
    func login(completionHandler: ((Data?) -> Void)) {
        let url = adapter.login()
        let data = url.data(using: .utf8)
        completionHandler(data)
    }
    
    func getStatus(completionHandler: ((Data?) -> Void)) {
        let statusDetailsMessage = adapter.client.getStatusDetails()
        var peerInfoArray: [PeerInfo] = []
        guard let statusDetailsMessage = statusDetailsMessage else {
            print("Did not receive status details")
            return
        }
        for i in 0..<statusDetailsMessage.size() {
            let peer = statusDetailsMessage.get(i)
            let peerInfo = PeerInfo(ip: peer!.ip, fqdn: peer!.fqdn, connStatus: peer!.connStatus)
            peerInfoArray.append(peerInfo)
        }
        
        
        let statusDetails = StatusDetails(ip: statusDetailsMessage.getIP(), fqdn: statusDetailsMessage.getFQDN() , managementStatus: self.adapter.clientState, peerInfo: peerInfoArray)
        
        do {
            let data = try PropertyListEncoder().encode(statusDetails)
            completionHandler(data)
            return
        } catch {
            do {
                let defaultStatus = StatusDetails(ip: "", fqdn: "", managementStatus: self.adapter.clientState, peerInfo: [])
                let data = try PropertyListEncoder().encode(defaultStatus)
                completionHandler(data)
                return
            } catch {
                print("Failed to convert default")
            }
            print("Failed to encode person: \(error.localizedDescription)")
            
        }
    }
    
    override func sleep(completionHandler: @escaping () -> Void) {
        // Add code here to get ready to sleep.
        completionHandler()
    }
    
    override func wake() {
        // Add code here to wake up.
    }
    
    func setTunnelSettings(tunnelNetworkSettings: NEPacketTunnelNetworkSettings) {
       setTunnelNetworkSettings(tunnelNetworkSettings) { error in
           if let error = error {
               // Handle Error
               print("error when assigning routes")
               return
           }
           print("Routes set")
       }
    }
}

func initializeLogging(loglevel: String) {
    let fileManager = FileManager.default

    let groupURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: "group.io.netbird.app")
    let logURL = groupURL?.appendingPathComponent("logfile.log")

    var error: NSError?
    var success = false
    
    let logMessage = "Starting new log file from extension" + "\n"
        
    guard let logURLValid = logURL else {
            print("Failed to get the log file URL.")
            return
        }
    
    if fileManager.fileExists(atPath: logURLValid.path) {
        // If the log file already exists, append the new message
        if let fileHandle = try? FileHandle(forWritingTo: logURLValid) {
            do {
                try "".write(to: logURLValid, atomically: true, encoding: .utf8)
            } catch {
                print("Error handling the log file: \(error)")
            }
            if let data = logMessage.data(using: .utf8) {
                fileHandle.write(data)
            }
            fileHandle.closeFile()
        } else {
            print("Failed to open the log file for writing.")
        }
    } else {
        // If the log file doesn't exist, create and write the new message
        do {
            try logMessage.write(to: logURLValid, atomically: true, encoding: .utf8)
        } catch {
            print("Failed to write to the log file: \(error.localizedDescription)")
        }
    }
    
    if let logPath = logURL?.path {
        
        success = NetBirdSDKInitializeLog(loglevel, logPath, &error)
    }
    if !success, let actualError = error {
               print("Failed to initialize log: \(actualError.localizedDescription)")
           }
}

