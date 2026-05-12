import WidgetKit
import NetworkExtension

@available(iOS 18.0, *)
struct VPNControlProvider: ControlValueProvider {

    var previewValue: Bool { false }

    func currentValue() async throws -> Bool {
        let managers = (try? await NETunnelProviderManager.loadAllFromPreferences()) ?? []
        return managers.first?.connection.status == .connected
    }
}
