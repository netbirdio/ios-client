//
//  ManagedConfigReader.swift
//  NetBird
//
//  Reads MDM-managed app configuration pushed via Apple Managed App Configuration (AppConfig).
//  Configuration is delivered through the com.apple.configuration.managed UserDefaults domain
//  by MDM solutions such as Microsoft Intune, Jamf Pro, VMware Workspace ONE, or Mosyle.
//
//  Key names match those defined in the Go SDK's ManagedConfig constants.
//

import Foundation
import NetBirdSDK
import os

/// Reads and applies MDM-managed app configuration from the Apple managed configuration domain.
///
/// ## How it works
/// - MDM pushes key-value pairs to the `com.apple.configuration.managed` UserDefaults domain
/// - This reader checks that domain for NetBird-specific keys
/// - Values are applied to the Go SDK's config file, overriding user preferences
/// - Setup keys trigger silent device registration without user interaction
///
/// ## Supported keys
/// - `managementUrl` — Management server URL
/// - `setupKey` — Setup key for silent device registration
/// - `adminUrl` — Admin dashboard URL  
/// - `preSharedKey` — WireGuard pre-shared key
/// - `rosenpassEnabled` — Enable Rosenpass post-quantum encryption
/// - `rosenpassPermissive` — Allow non-Rosenpass peers
/// - `disableAutoConnect` — Prevent auto-connect on launch
class ManagedConfigReader {

    private static let logger = Logger(subsystem: "io.netbird.app", category: "ManagedConfigReader")

    /// The Apple-native MDM managed configuration domain
    private static let managedDomain = "com.apple.configuration.managed"

    /// Reads managed configuration from the MDM domain.
    /// Returns a populated ManagedConfig, or nil if no MDM config is available.
    static func read() -> NetBirdSDKManagedConfig? {
        guard let managedDefaults = UserDefaults(suiteName: managedDomain) else {
            logger.debug("ManagedConfigReader: managed defaults domain not available")
            return nil
        }

        let dict = managedDefaults.dictionaryRepresentation()

        // Check if any NetBird keys are present
        let managementUrlKey = NetBirdSDKGetManagedConfigKeyManagementURL()
        let setupKeyKey = NetBirdSDKGetManagedConfigKeySetupKey()
        let adminUrlKey = NetBirdSDKGetManagedConfigKeyAdminURL()
        let preSharedKeyKey = NetBirdSDKGetManagedConfigKeyPreSharedKey()
        let rosenpassEnabledKey = NetBirdSDKGetManagedConfigKeyRosenpassEnabled()
        let rosenpassPermissiveKey = NetBirdSDKGetManagedConfigKeyRosenpassPermissive()
        let disableAutoConnectKey = NetBirdSDKGetManagedConfigKeyDisableAutoConnect()

        guard let config = NetBirdSDKNewManagedConfig() else {
            logger.error("ManagedConfigReader: failed to create ManagedConfig")
            return nil
        }

        if let managementUrl = dict[managementUrlKey] as? String, !managementUrl.isEmpty {
            config.setManagementURL(managementUrl)
            logger.info("ManagedConfigReader: management URL configured")
        }

        if let setupKey = dict[setupKeyKey] as? String, !setupKey.isEmpty {
            config.setSetupKey(setupKey)
            // Do not log the setup key value for security
            logger.info("ManagedConfigReader: setup key configured")
        }

        if let adminUrl = dict[adminUrlKey] as? String, !adminUrl.isEmpty {
            config.setAdminURL(adminUrl)
            logger.info("ManagedConfigReader: admin URL configured")
        }

        if let preSharedKey = dict[preSharedKeyKey] as? String, !preSharedKey.isEmpty {
            config.setPreSharedKey(preSharedKey)
            logger.info("ManagedConfigReader: pre-shared key configured")
        }

        if let rosenpassEnabled = dict[rosenpassEnabledKey] as? Bool {
            config.setRosenpassEnabled(rosenpassEnabled)
            logger.info("ManagedConfigReader: Rosenpass enabled=\(rosenpassEnabled)")
        }

        if let rosenpassPermissive = dict[rosenpassPermissiveKey] as? Bool {
            config.setRosenpassPermissive(rosenpassPermissive)
            logger.info("ManagedConfigReader: Rosenpass permissive=\(rosenpassPermissive)")
        }

        if let disableAutoConnect = dict[disableAutoConnectKey] as? Bool {
            config.setDisableAutoConnect(disableAutoConnect)
            logger.info("ManagedConfigReader: disable auto-connect=\(disableAutoConnect)")
        }

        guard config.hasConfig() else {
            logger.debug("ManagedConfigReader: no NetBird keys found in managed config")
            return nil
        }

        logger.info("ManagedConfigReader: MDM managed configuration loaded successfully")
        return config
    }

    /// Returns true if any MDM-managed configuration is available.
    static func hasManagedConfig() -> Bool {
        guard let config = read() else { return false }
        return config.hasConfig()
    }

    /// Applies MDM config to the config file and optionally performs setup key registration.
    /// - Parameters:
    ///   - configPath: Path to the NetBird config file
    ///   - deviceName: Device name for registration
    /// - Returns: true if MDM config was applied
    @discardableResult
    static func applyIfAvailable(configPath: String, deviceName: String) -> Bool {
        guard let config = read() else { return false }

        do {
            try config.apply(configPath)
            logger.info("ManagedConfigReader: MDM config applied to \(configPath)")
        } catch {
            logger.error("ManagedConfigReader: failed to apply MDM config: \(error.localizedDescription)")
            return false
        }

        // If MDM provides a setup key, attempt silent registration.
        // Pass the MDM management URL so NewAuth connects to the correct server.
        if config.hasSetupKey() {
            let mgmtUrl = config.getManagementURL() ?? ""
            do {
                guard let auth = NetBirdSDKNewAuth(configPath, mgmtUrl, nil) else {
                    logger.warning("ManagedConfigReader: failed to create Auth for setup key login")
                    return true
                }
                try auth.loginWithSetupKeySync(config.getSetupKey(), deviceName: deviceName)
                logger.info("ManagedConfigReader: silent setup key registration completed")
            } catch {
                // Setup key login may fail if already registered or key expired.
                // This is not fatal — continue with normal flow.
                logger.warning("ManagedConfigReader: setup key login skipped or failed: \(error.localizedDescription)")
            }
        }

        return true
    }
}
