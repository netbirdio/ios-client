//
//  VPNOnDemandView.swift
//  NetBird
//
//  VPN On Demand settings screen (iOS only).
//

import SwiftUI
import NetworkExtension

#if os(iOS)

struct VPNOnDemandView: View {
    @EnvironmentObject var viewModel: ViewModel
    @State private var currentSSID: String?
    @State private var showAddNetworkField = false
    @State private var newNetworkName = ""

    private let wifiOptions = WiFiOnDemandPolicy.allCases
    private let cellularOptions = CellularOnDemandPolicy.allCases

    var body: some View {
        Form {
            Section {
                Text("Use VPN On Demand to automatically connect NetBird on this iPhone.")
                    .font(.footnote)
                    .foregroundColor(Color("TextSecondary"))

                Toggle("VPN On Demand", isOn: $viewModel.connectOnDemand)
                    .toggleStyle(SwitchToggleStyle(tint: .accentColor))
                    .onChange(of: viewModel.connectOnDemand) { value in
                        viewModel.setConnectOnDemand(isEnabled: value)
                    }
            }

            if viewModel.connectOnDemand {
                Section {
                    HStack {
                        Image(systemName: "wifi")
                            .foregroundColor(.accentColor)
                        Text("Wi-Fi")
                        Spacer()
                        Picker("", selection: $viewModel.onDemandWiFiPolicy) {
                            ForEach(WiFiOnDemandPolicy.allCases, id: \.self) { policy in
                                Text(policy.displayName).tag(policy)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    HStack {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .foregroundColor(.accentColor)
                        Text("Cellular")
                        Spacer()
                        Picker("", selection: $viewModel.onDemandCellularPolicy) {
                            ForEach(CellularOnDemandPolicy.allCases, id: \.self) { policy in
                                Text(policy.displayName).tag(policy)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                } header: {
                    Text("Connect Automatically On")
                } footer: {
                    Text(connectionDescription)
                }
                .onChange(of: viewModel.onDemandWiFiPolicy) { _ in
                    viewModel.saveOnDemandSettings()
                }
                .onChange(of: viewModel.onDemandCellularPolicy) { _ in
                    viewModel.saveOnDemandSettings()
                }

                if viewModel.onDemandWiFiPolicy == .onlyOn {
                    networkListSection(
                        header: "Connect Only On These Wi-Fi Networks"
                    )
                }

                if viewModel.onDemandWiFiPolicy == .exceptOn {
                    networkListSection(
                        header: "Except On These Wi-Fi Networks"
                    )
                }
            }
        }
        .navigationTitle("VPN On Demand")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            fetchCurrentSSID()
        }
    }

    private func networkListSection(header: String) -> some View {
        Section(header: Text(header)) {
            ForEach(viewModel.onDemandWiFiNetworks, id: \.self) { network in
                HStack {
                    Image(systemName: "wifi")
                        .foregroundColor(Color("TextSecondary"))
                    Text(network)
                }
            }
            .onDelete { offsets in
                viewModel.removeOnDemandWiFiNetwork(at: offsets)
            }

            if let ssid = currentSSID, !viewModel.onDemandWiFiNetworks.contains(ssid) {
                Button {
                    viewModel.addOnDemandWiFiNetwork(ssid)
                } label: {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(.accentColor)
                        Text("Add current: ")
                            .foregroundColor(Color("TextPrimary"))
                        Text(ssid)
                            .foregroundColor(Color("TextSecondary"))
                    }
                }
            }

            if showAddNetworkField {
                HStack {
                    TextField("Network name", text: $newNetworkName)
                        .disableAutocorrection(true)
                        .autocapitalization(.none)
                    Button("Add") {
                        viewModel.addOnDemandWiFiNetwork(newNetworkName)
                        newNetworkName = ""
                        showAddNetworkField = false
                    }
                    .disabled(newNetworkName.isEmpty)
                }
            } else {
                Button {
                    showAddNetworkField = true
                } label: {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(.accentColor)
                        Text("Add new network")
                            .foregroundColor(Color("TextPrimary"))
                    }
                }
            }
        }
    }

    private var connectionDescription: String {
        var parts: [String] = []

        switch viewModel.onDemandWiFiPolicy {
        case .always:
            parts.append("NetBird will connect whenever this iPhone joins any Wi-Fi network")
        case .onlyOn:
            if viewModel.onDemandWiFiNetworks.isEmpty {
                parts.append("NetBird will not connect on Wi-Fi until you add networks to the list")
            } else {
                parts.append("NetBird will connect when this iPhone joins any of the Wi-Fi networks specified below")
            }
        case .exceptOn:
            parts.append("NetBird will connect on Wi-Fi, except on the networks listed below")
        case .never:
            parts.append("NetBird will disconnect when this iPhone uses Wi-Fi")
        case .doNothing:
            break
        }

        switch viewModel.onDemandCellularPolicy {
        case .always:
            if parts.isEmpty {
                parts.append("NetBird will connect whenever this iPhone uses cellular data")
            } else {
                parts.append("It will also connect whenever this iPhone uses cellular data")
            }
        case .never:
            if parts.isEmpty {
                parts.append("NetBird will disconnect when this iPhone uses cellular data")
            } else {
                parts.append("It will disconnect when using cellular data")
            }
        case .doNothing:
            break
        }

        if parts.isEmpty {
            return "NetBird won't automatically connect or disconnect."
        }
        return parts.joined(separator: ". ") + "."
    }

    private func fetchCurrentSSID() {
        NEHotspotNetwork.fetchCurrent { network in
            DispatchQueue.main.async {
                self.currentSSID = network?.ssid
            }
        }
    }
}

#endif
