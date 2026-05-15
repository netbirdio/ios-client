import SwiftUI
import WidgetKit

@available(iOS 18.0, *)
struct NetBirdVPNControl: ControlWidget {

    static let kind = "io.netbird.vpn.control"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: Self.kind,
            provider: VPNControlProvider()
        ) { state in
            ControlWidgetButton(action: VPNControlIntent()) {
                Label(
                    state.isActive ? "Connected" : "Disconnected",
                    systemImage: state.isActive ? "shield.fill" : "shield.slash"
                )
            }
        }
        .displayName("NetBird VPN")
        .description("Connect or disconnect NetBird VPN from Control Center.")
    }
}
