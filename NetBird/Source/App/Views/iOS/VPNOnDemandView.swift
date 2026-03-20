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

    /// All non-current SSIDs to display: known + manually added, deduplicated.
    private var otherNetworks: [String] {
        var result = viewModel.knownSSIDs.filter { $0 != currentSSID }
        for ssid in viewModel.onDemandWiFiNetworks where ssid != currentSSID && !result.contains(ssid) {
            result.append(ssid)
        }
        return result
    }

    private func networkListSection(header: String) -> some View {
        Section(header: Text(header)) {
            // Current connected network
            if let ssid = currentSSID {
                Button {
                    toggleNetwork(ssid)
                } label: {
                    HStack {
                        Image(systemName: viewModel.onDemandWiFiNetworks.contains(ssid) ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(viewModel.onDemandWiFiNetworks.contains(ssid) ? .accentColor : Color("TextSecondary"))
                        Image(systemName: "wifi")
                            .foregroundColor(.accentColor)
                        Text(ssid)
                            .foregroundColor(Color("TextPrimary"))
                        Spacer()
                        Text("Connected")
                            .font(.caption)
                            .foregroundColor(Color("TextSecondary"))
                    }
                }
            }

            // Other networks
            ForEach(otherNetworks, id: \.self) { ssid in
                networkRow(ssid: ssid)
            }

            // Add network manually
            if showAddNetworkField {
                HStack {
                    TextField("Network name", text: $newNetworkName)
                        .disableAutocorrection(true)
                        .autocapitalization(.none)
                    Button("Add") {
                        let trimmed = newNetworkName.trimmingCharacters(in: .whitespacesAndNewlines)
                        viewModel.recordKnownSSID(trimmed)
                        viewModel.addOnDemandWiFiNetwork(trimmed)
                        newNetworkName = ""
                        showAddNetworkField = false
                    }
                    .disabled(newNetworkName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || viewModel.onDemandWiFiNetworks.contains(newNetworkName.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            } else {
                Button {
                    showAddNetworkField = true
                } label: {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(.accentColor)
                        Text("Add other network")
                            .foregroundColor(Color("TextPrimary"))
                    }
                }
            }
        }
    }

    private func networkRow(ssid: String) -> some View {
        HStack {
            Button {
                toggleNetwork(ssid)
            } label: {
                HStack {
                    Image(systemName: viewModel.onDemandWiFiNetworks.contains(ssid) ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(viewModel.onDemandWiFiNetworks.contains(ssid) ? .accentColor : Color("TextSecondary"))
                    Image(systemName: "wifi")
                        .foregroundColor(Color("TextSecondary"))
                    Text(ssid)
                        .foregroundColor(Color("TextPrimary"))
                }
            }
            .buttonStyle(.borderless)
            Spacer()
            Button {
                removeNetworkEntirely(ssid)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(Color("TextSecondary"))
            }
            .buttonStyle(.borderless)
        }
    }

    private func toggleNetwork(_ ssid: String) {
        if let idx = viewModel.onDemandWiFiNetworks.firstIndex(of: ssid) {
            viewModel.removeOnDemandWiFiNetwork(at: IndexSet(integer: idx))
        } else {
            viewModel.addOnDemandWiFiNetwork(ssid)
        }
    }

    private func removeNetworkEntirely(_ ssid: String) {
        if let idx = viewModel.onDemandWiFiNetworks.firstIndex(of: ssid) {
            viewModel.removeOnDemandWiFiNetwork(at: IndexSet(integer: idx))
        }
        viewModel.removeKnownSSID(ssid)
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
                if let ssid = network?.ssid {
                    viewModel.recordKnownSSID(ssid)
                }
            }
        }
    }
}

#endif
