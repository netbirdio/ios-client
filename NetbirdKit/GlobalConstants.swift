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

    // Profile whose account the login browser last authenticated. The system auth
    // session shares one Safari cookie jar across all profiles, so a login for any
    // other profile must force account selection instead of silently reusing that
    // session.
    static let keyLastAuthenticatedProfile = "netbird.lastAuthenticatedProfile"

    // Local notification identifiers
    static let notificationLoginRequired = "netbird.login.required"
}
