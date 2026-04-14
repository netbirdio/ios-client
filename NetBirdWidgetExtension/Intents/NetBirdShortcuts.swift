import AppIntents

@available(iOS 16.0, *)
struct NetBirdShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ConnectVPNIntent(),
            phrases: [
                "Connect \(.applicationName) VPN",
                "Turn on \(.applicationName) VPN",
                "Enable \(.applicationName) VPN"
            ],
            shortTitle: "Connect VPN",
            systemImageName: "lock.shield"
        )

        AppShortcut(
            intent: DisconnectVPNIntent(),
            phrases: [
                "Disconnect \(.applicationName) VPN",
                "Turn off \(.applicationName) VPN",
                "Disable \(.applicationName) VPN"
            ],
            shortTitle: "Disconnect VPN",
            systemImageName: "lock.slash"
        )

        AppShortcut(
            intent: VPNStatusIntent(),
            phrases: [
                "\(.applicationName) VPN status",
                "Is \(.applicationName) VPN connected",
                "Check \(.applicationName) VPN"
            ],
            shortTitle: "VPN Status",
            systemImageName: "network"
        )
    }
}
