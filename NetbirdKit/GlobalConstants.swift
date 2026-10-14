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

    /// Darwin notification posted by the network extension whenever the core's
    /// network map moves: a sync was applied, a route gained or lost its routing
    /// peer, a peer's connection state flipped. The routes only exist in the
    /// extension process, and the app's read on `.connected` lands before the
    /// first network map has arrived, so without this the app would never learn
    /// that there is something to re-read. Carries no payload; the app answers
    /// it with a GetRoutes round-trip.
    static let darwinNotificationNetworkMapChanged = "io.netbird.networkMapChanged"

    // Local notification identifiers
    static let notificationLoginRequired = "netbird.login.required"
    static let notificationMDMPolicyApplied = "netbird.mdm.policyApplied"
}
