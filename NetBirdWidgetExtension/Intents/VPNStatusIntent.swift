import AppIntents
import NetworkExtension

@available(iOS 16.0, *)
struct VPNStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Get NetBird VPN Status"
    static var description: IntentDescription = "Check whether NetBird VPN is connected."
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let manager = try await VPNIntentHelpers.loadManager() else {
            return .result(dialog: "NetBird VPN is not configured.")
        }

        if VPNIntentHelpers.isLoginRequired {
            return .result(dialog: "NetBird VPN requires sign-in.")
        }

        let status = WidgetVPNStatus(neStatus: manager.connection.status)
        let ip = VPNIntentHelpers.defaults?.string(forKey: WidgetConstants.keyIP) ?? ""
        let detail = status == .connected && !ip.isEmpty ? " Your IP is \(ip)." : ""

        return .result(dialog: "NetBird VPN is \(status.displayText.lowercased()).\(detail)")
    }
}
