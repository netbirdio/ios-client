import SwiftUI
import WidgetKit

@available(iOS 18.0, *)
struct NetBirdVPNControl: ControlWidget {

    static let kind = "io.netbird.vpn.control"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: Self.kind,
            provider: VPNControlProvider()
        ) { isConnected in
            ControlWidgetToggle(
                "NetBird VPN",
                isOn: isConnected,
                action: ToggleVPNControlIntent(value: !isConnected)
            ) { isOn in
                Label(
                    isOn ? "Connected" : "Disconnected",
                    systemImage: isOn ? "shield.fill" : "shield.slash"
                )
            }
        }
        .displayName("NetBird VPN")
        .description("Connect or disconnect NetBird VPN from Control Center.")
    }
}
