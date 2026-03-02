//
//  PeerDetailSheet.swift
//  NetBird
//

import SwiftUI

struct PeerDetailSheet: View {
    @ObservedObject var peer: PeerInfo
    @Environment(\.presentationMode) var presentationMode

    @State private var relativeDateText: String = ""

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    var body: some View {
        NavigationView {
            List {
                Section {
                    detailRow("Status", peer.connStatus)
                    detailRow("Last status update", relativeDateText)
                    detailRow("Connection type", peer.relayed ? "Relayed" : "P2P")
                    detailRow("Direct", peer.direct.description)
                    detailRow("Latency", peer.latency)
                    detailRow("Quantum resistance", peer.rosenpassEnabled.description)
                }

                Section(header: Text("ICE")) {
                    detailRow("Candidate (Local/Remote)", "\(peer.localIceCandidateType)/\(peer.remoteIceCandidateType)")
                    detailRow("Local endpoint", peer.localIceCandidateEndpoint)
                    detailRow("Remote endpoint", peer.remoteIceCandidateEndpoint)
                }

                if !peer.routes.isEmpty {
                    Section(header: Text("Routes")) {
                        ForEach(peer.routes, id: \.self) { route in
                            Text(route)
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                }

                Section {
                    detailRow("Public key", peer.pubKey)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(peer.fqdn)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { presentationMode.wrappedValue.dismiss() }
                }
            }
        }
        .onAppear { updateRelativeDate() }
    }

    @ViewBuilder
    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundColor(Color("TextPrimary"))
            Spacer()
            Text(value)
                .foregroundColor(.gray)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }

    private func updateRelativeDate() {
        if peer.connStatusUpdate == "0001-01-01 00:00:00" {
            relativeDateText = "never"
            return
        }
        if let date = dateFormatter.date(from: peer.connStatusUpdate) {
            relativeDateText = relativeFormatter.localizedString(for: date, relativeTo: Date())
        } else {
            relativeDateText = peer.connStatusUpdate
        }
    }
}
