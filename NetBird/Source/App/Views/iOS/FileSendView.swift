//
//  FileSendView.swift
//  NetBird
//
//  The send sheet: pick what to share, then tap a peer to send. The screen
//  stays put so the same content can be fanned out to several peers, each row
//  tracking its own transfer.
//

import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)

struct FileSendView: View {
    @EnvironmentObject var viewModel: ViewModel
    @ObservedObject var filesVM: FilesViewModel
    @Environment(\.presentationMode) private var presentationMode

    enum ContentKind: String, CaseIterable {
        case files = "Files"
        case text = "Text"
    }

    @State private var contentKind: ContentKind = .files
    @State private var stagedFiles: [FileDropSendFile] = []
    @State private var stagingFailed = false
    @State private var text: String = ""
    @State private var peerQuery: String = ""
    @State private var showFilePicker = false
    @State private var rowStates: [String: SendRowState] = [:]
    @State private var targetToStop: SendTarget? = nil

    struct SendRowState {
        var transferID: String? = nil
        var waiting = false
        var failure: String? = nil
    }

    struct SendTarget: Identifiable {
        let pubKey: String
        let name: String
        let ip: String
        let connected: Bool

        var id: String { pubKey }

        func matches(_ query: String) -> Bool {
            let q = query.trimmingCharacters(in: .whitespaces).lowercased()
            if q.isEmpty { return true }
            return name.lowercased().contains(q) || ip.contains(q)
        }
    }

    var body: some View {
        NavigationView {
            ZStack {
                Color("BgMenu")
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    contentPicker
                    peerListHeader
                    peerList
                }
            }
            .navigationTitle("Send to")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .fileImporter(isPresented: $showFilePicker,
                      allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                DispatchQueue.global(qos: .userInitiated).async {
                    let staged = FilesViewModel.stageFiles(urls)
                    DispatchQueue.main.async {
                        stagingFailed = staged.isEmpty && !urls.isEmpty
                        stagedFiles = staged
                    }
                }
            case .failure:
                stagingFailed = true
            }
        }
        .alert(item: $targetToStop) { target in
            Alert(
                title: Text("Stop sending"),
                message: Text("Stop sending to this peer?"),
                primaryButton: .destructive(Text("Stop")) {
                    stopSending(to: target)
                },
                secondaryButton: .cancel()
            )
        }
    }

    // MARK: - Content selection

    private var contentPicker: some View {
        VStack(spacing: 12) {
            Picker("", selection: $contentKind) {
                ForEach(ContentKind.allCases, id: \.self) { kind in
                    Text(kind.rawValue).tag(kind)
                }
            }
            .pickerStyle(SegmentedPickerStyle())

            switch contentKind {
            case .files:
                Button {
                    showFilePicker = true
                } label: {
                    HStack {
                        Image(systemName: "doc.badge.plus")
                        Text(stagedFiles.isEmpty ? "Choose files" : filesSummary)
                            .lineLimit(2)
                        Spacer()
                    }
                    .padding(12)
                    .background(Color("BgPeerCard"))
                    .foregroundColor(Color("TextPrimary"))
                    .cornerRadius(8)
                }
                if stagingFailed {
                    Text("The selected files could not be read")
                        .font(.footnote)
                        .foregroundColor(.red)
                }
            case .text:
                TextField("Text to send", text: $text)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }
        }
        .padding(.horizontal)
        .padding(.top, 12)
    }

    private var filesSummary: String {
        let totalSize = stagedFiles.reduce(Int64(0)) { $0 + $1.size }
        let sizeLabel = FileDropFormat.size(totalSize)
        if stagedFiles.count == 1 {
            return "\(stagedFiles[0].name) · \(sizeLabel)"
        }
        return "\(stagedFiles.count) files · \(sizeLabel)"
    }

    private var hasContent: Bool {
        switch contentKind {
        case .files: return !stagedFiles.isEmpty
        case .text: return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    // MARK: - Peers

    private var peerListHeader: some View {
        TextField("Search peers", text: $peerQuery)
            .textFieldStyle(RoundedBorderTextFieldStyle())
            .autocapitalization(.none)
            .disableAutocorrection(true)
            .padding(.horizontal)
            .padding(.vertical, 8)
    }

    /// Deliberately not filtered on connection status: an idle peer is the
    /// normal resting state under lazy connections, and the transfer's own
    /// packets are what wake it. Connected peers first, then by name, so the
    /// same peer sits in the same place as on the Peers screen.
    private var targets: [SendTarget] {
        viewModel.peerViewModel.peerInfo
            .filter { !$0.ip.isEmpty }
            .map {
                SendTarget(pubKey: $0.pubKey,
                           name: $0.fqdn,
                           ip: $0.ip,
                           connected: $0.connStatus == "Connected")
            }
            .sorted {
                if $0.connected != $1.connected { return $0.connected }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    @ViewBuilder
    private var peerList: some View {
        let shown = targets.filter { $0.matches(peerQuery) }

        if viewModel.vpnDisplayState != .connected {
            emptyState("NetBird is not running")
        } else if shown.isEmpty {
            emptyState(targets.isEmpty ? "No peers to send to" : "No matching peers")
        } else {
            List(shown) { target in
                SendTargetRow(target: target, status: statusLabel(for: target))
                    .contentShape(Rectangle())
                    .onTapGesture { tapped(target) }
            }
            .listStyle(InsetGroupedListStyle())
        }
    }

    private func emptyState(_ message: String) -> some View {
        VStack {
            Spacer()
            Text(message)
                .foregroundColor(Color("TextSecondary"))
            Spacer()
        }
    }

    // MARK: - Row state

    private func transfer(for target: SendTarget) -> FileDropTransferInfo? {
        guard let transferID = rowStates[target.pubKey]?.transferID else { return nil }
        return filesVM.transfers.first { $0.id == transferID }
    }

    private func statusLabel(for target: SendTarget) -> (String, Color) {
        guard let state = rowStates[target.pubKey] else {
            return ("", Color("TextSecondary"))
        }
        if let failure = state.failure {
            return ("Could not send: \(failure)", .red)
        }
        guard let transfer = transfer(for: target) else {
            return (state.waiting ? "Waiting…" : "", Color("TextSecondary"))
        }
        if transfer.transferState == .completed {
            return ("✓ Sent", .green)
        }
        if transfer.transferState == .pending {
            return ("Waiting…", Color("TextSecondary"))
        }
        return (FileDropFormat.outcome(for: transfer), FileDropFormat.outcomeColor(for: transfer))
    }

    // MARK: - Sending

    /// Tap is the send: no confirm step, and the row itself carries the whole
    /// lifecycle. A second tap on a live send offers to stop it.
    private func tapped(_ target: SendTarget) {
        if let transfer = transfer(for: target), !transfer.isTerminal {
            targetToStop = target
            return
        }
        if rowStates[target.pubKey]?.waiting == true {
            return
        }
        guard hasContent else { return }

        rowStates[target.pubKey] = SendRowState(waiting: true)

        let request = FileDropSendRequest(
            peerKey: target.pubKey,
            peerName: target.name,
            peerIP: target.ip,
            text: contentKind == .text ? text.trimmingCharacters(in: .whitespacesAndNewlines) : "",
            files: contentKind == .files ? stagedFiles : []
        )

        filesVM.send(request) { result in
            switch result {
            case .success(let transferID):
                rowStates[target.pubKey] = SendRowState(transferID: transferID)
                filesVM.refresh()
            case .failure(let error):
                rowStates[target.pubKey] = SendRowState(failure: error.localizedDescription)
            }
        }
    }

    private func stopSending(to target: SendTarget) {
        guard let transfer = transfer(for: target) else { return }
        filesVM.stop(transfer)
    }
}

private struct SendTargetRow: View {
    let target: FileSendView.SendTarget
    let status: (String, Color)

    var body: some View {
        HStack {
            Circle()
                .fill(target.connected ? Color.green : Color("TextSecondary"))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(target.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Color("TextPrimary"))
                    .lineLimit(1)
                Text(target.ip)
                    .font(.system(size: 13))
                    .foregroundColor(Color("TextSecondary"))
            }

            Spacer()

            Text(status.0)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(status.1)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}

#endif
