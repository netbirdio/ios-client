//
//  GlobalConstants.swift
//  NetBird
//
//  Created by Diego Romar on 03/12/25.
//

struct GlobalConstants {
    #if os(tvOS)
    static let userPreferencesSuiteName = "group.io.netbird.app.tv"
    #else
    static let userPreferencesSuiteName = "group.io.netbird.app"
    #endif

    static let keyForceRelayConnection = "isConnectionForceRelayed"
    static let keyLoginRequired = "netbird.loginRequired"
    static let keyNetworkUnavailable = "netbird.networkUnavailable"
    static let keyConnectOnDemand = "netbird.connectOnDemand"
    static let keyOnDemandWiFiPolicy = "netbird.onDemand.wifiPolicy"
    static let keyOnDemandCellularPolicy = "netbird.onDemand.cellularPolicy"
    static let keyOnDemandWiFiNetworks = "netbird.onDemand.wifiNetworks"
    static let keyKnownSSIDs = "netbird.knownSSIDs"

    // Widget shared state keys
    static let keyWidgetVPNStatus = "netbird.widget.vpnStatus"
    static let keyWidgetIP = "netbird.widget.ip"
    static let keyWidgetFQDN = "netbird.widget.fqdn"
    // Active profile paths stored by the main app so the widget intent can
    // start the tunnel without the main app running (mirrors WidgetConstants).
    static let keyWidgetActiveConfigPath = "netbird.widget.activeConfigPath"
    static let keyWidgetActiveStatePath  = "netbird.widget.activeStatePath"

    /// startVPNTunnel(options:) key. Set by the main app when it has just verified the
    /// login state itself (its own isLoginRequired() check, or a login it just completed),
    /// letting the extension skip its duplicate check — each such check is a full Login RPC
    /// against the management server. Absent for starts the main app did not initiate
    /// (On Demand, widget intent), where the extension must still verify.
    static let optionLoginVerified = "loginVerified"

    static let configFileName = "netbird.cfg"
    static let stateFileName = "state.json"
    static let serverURLFileName = "netbird_server_url"

    /// Set by the extension when an MDM policy change triggered an engine
    /// restart; the main app clears it and tells the user the configuration
    /// was updated by their IT policy.
    static let keyMDMPolicyApplied = "netbird.mdm.policyApplied"

    /// App Group copy of the managed configuration, written by the app.
    ///
    /// iOS delivers `com.apple.configuration.managed` to the managed app's own
    /// preferences domain only. The network extension runs as a separate bundle
    /// with a separate domain and never receives it, so the app mirrors the
    /// dictionary here and the extension reads it back.
    static let keyMDMManagedConfigMirror = "netbird.mdm.managedConfigMirror"

    /// Darwin notification posted by the app whenever that mirror changes.
    /// UserDefaults.didChangeNotification is process-local and cannot tell a
    /// running extension anything; this crosses the process boundary.
    static let darwinNotificationMDMPolicyChanged = "io.netbird.mdm.policyChanged"

    // Local notification identifiers
    static let notificationLoginRequired = "netbird.login.required"
    static let notificationMDMPolicyApplied = "netbird.mdm.policyApplied"
}
