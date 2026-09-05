//
//  FileSendView.swift
//  NetBird
//
//  The send sheet: pick what to share, then send it to one or more peers. The
//  screen stays put so the same content can be fanned out, each row tracking
//  its own transfer.
//
//  Sending is an explicit button on the row rather than a tap on the row
//  itself: on iOS a tap is a navigation gesture, and a send is neither
//  navigation nor something to trigger by accident.
//

import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)

struct FileSendView: View {
    @EnvironmentObject var viewModel: ViewModel
    @ObservedObject var filesVM: FilesViewModel
    @Environment(\.presentationMode) private var presentationMode

    /// A sheet opened from a peer's own row carries that peer into the picker.
    let presetPeer: String?

    init(filesVM: FilesViewModel, presetPeer: String? = nil) {
        self.filesVM = filesVM
        self.presetPeer = presetPeer
        _peerQuery = State(initialValue: presetPeer ?? "")
    }

    enum ContentKind: String, CaseIterable {
        case files
        case text

        var label: LocalizedStringKey {
            switch self {
            case .files: return "Files"
            case .text: return "Text"
            }
        }
    }

    @State private var contentKind: ContentKind = .files
    @State private var stagedFiles: [FileDropSendFile] = []
    @State private var stagingFailed = false
    @State private var text: String = ""
    @State private var peerQuery: String
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
            List {
                contentSection
                peerSection
            }
            .listStyle(InsetGroupedListStyle())
            .navigationTitle("Send to")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $peerQuery, prompt: "Search peers")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
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
        .confirmationDialog(
            targetToStop?.name ?? "",
            isPresented: Binding(
                get: { targetToStop != nil },
                set: { if !$0 { targetToStop = nil } }
            ),
            titleVisibility: .visible,
            presenting: targetToStop
        ) { target in
            Button("Stop", role: .destructive) { stopSending(to: target) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Stop sending to this peer?")
        }
    }

    // MARK: - Content selection

    private var contentSection: some View {
        Section(header: Text("What to send")) {
            Picker("", selection: $contentKind) {
                ForEach(ContentKind.allCases, id: \.self) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .pickerStyle(SegmentedPickerStyle())
            .listRowSeparator(.hidden)

            switch contentKind {
            case .files:
                Button {
                    showFilePicker = true
                } label: {
                    HStack {
                        Image(systemName: "doc.badge.plus")
                        // The summary is composed from file names and a byte
                        // count, so it is shown verbatim rather than looked up.
                        if stagedFiles.isEmpty {
                            Text("Choose files")
                        } else {
                            Text(verbatim: filesSummary)
                                .lineLimit(2)
                        }
                        Spacer()
                    }
                    .foregroundColor(Color("TextPrimary"))
                }
                .buttonStyle(.borderless)

                if stagingFailed {
                    Text("The selected files could not be read")
                        .font(.footnote)
                        .foregroundColor(Color(.systemRed))
                }
            case .text:
                // Multi-line: what people send is usually a snippet, not a word,
                // and a one-line field hides everything past its width.
                TextEditor(text: $text)
                    .frame(minHeight: 88)
                    .font(.body)

                Button {
                    paste()
                } label: {
                    Label("Paste from clipboard", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.borderless)
                .disabled(!UIPasteboard.general.hasStrings)
            }
        }
    }

    private var filesSummary: String {
        let totalSize = stagedFiles.reduce(Int64(0)) { $0 + $1.size }
        let sizeLabel = FileDropFormat.size(totalSize)
        if stagedFiles.count == 1 {
            return "\(stagedFiles[0].name) · \(sizeLabel)"
        }
        let format = NSLocalizedString("file_drop_send_files_summary", value: "%1$d files · %2$@",
                                       comment: "file count, total size")
        return String(format: format, stagedFiles.count, sizeLabel)
    }

    private var hasContent: Bool {
        switch contentKind {
        case .files: return !stagedFiles.isEmpty
        case .text: return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func paste() {
        guard let clipboard = UIPasteboard.general.string,
              !clipboard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        text = clipboard
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    // MARK: - Peers

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
    private var peerSection: some View {
        let shown = targets.filter { $0.matches(peerQuery) }

        Section(header: Text("Send to")) {
            if viewModel.vpnDisplayState != .connected {
                emptyRow("NetBird is not running")
            } else if shown.isEmpty {
                emptyRow(targets.isEmpty ? "No peers to send to" : "No matching peers")
            } else {
                ForEach(shown) { target in
                    SendTargetRow(target: target,
                                  status: statusLabel(for: target),
                                  action: rowAction(for: target),
                                  enabled: hasContent,
                                  onTap: { tapped(target) })
                }
            }
        }
    }

    private func emptyRow(_ message: LocalizedStringKey) -> some View {
        Text(message)
            .font(.subheadline)
            .foregroundColor(Color("TextSecondary"))
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 12)
    }

    // MARK: - Row state

    private func transfer(for target: SendTarget) -> FileDropTransferInfo? {
        guard let transferID = rowStates[target.pubKey]?.transferID else { return nil }
        return filesVM.transfers.first { $0.id == transferID }
    }

    /// What the row's button offers right now. A live send can be stopped, a
    /// finished one can be sent again, everything else is a plain send.
    private func rowAction(for target: SendTarget) -> SendTargetRow.Action {
        if let transfer = transfer(for: target), !transfer.isTerminal {
            return .stop
        }
        if rowStates[target.pubKey]?.waiting == true {
            return .inFlight
        }
        return .send
    }

    private func statusLabel(for target: SendTarget) -> (String, Color) {
        guard let state = rowStates[target.pubKey] else {
            return ("", Color("TextSecondary"))
        }
        if let failure = state.failure {
            let format = NSLocalizedString("file_drop_share_failed", value: "Could not send: %@",
                                           comment: "error message")
            return (String(format: format, failure), Color(.systemRed))
        }
        guard let transfer = transfer(for: target) else {
            let waiting = NSLocalizedString("file_drop_share_state_waiting", value: "Waiting…", comment: "")
            return (state.waiting ? waiting : "", Color("TextSecondary"))
        }
        if transfer.transferState == .completed {
            return (NSLocalizedString("file_drop_share_state_sent", value: "✓ Sent", comment: ""),
                    Color(.systemGreen))
        }
        if transfer.transferState == .pending {
            return (NSLocalizedString("file_drop_share_state_waiting", value: "Waiting…", comment: ""),
                    Color("TextSecondary"))
        }
        return (FileDropFormat.outcome(for: transfer), FileDropFormat.outcomeColor(for: transfer))
    }

    // MARK: - Sending

    private func tapped(_ target: SendTarget) {
        switch rowAction(for: target) {
        case .stop:
            targetToStop = target
        case .inFlight:
            return
        case .send:
            send(to: target)
        }
    }

    private func send(to target: SendTarget) {
        guard hasContent else { return }

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
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
                UINotificationFeedbackGenerator().notificationOccurred(.error)
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
    enum Action {
        case send
        case stop
        case inFlight
    }

    let target: FileSendView.SendTarget
    let status: (String, Color)
    let action: Action
    let enabled: Bool
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(target.connected ? Color(.systemGreen) : Color("TextSecondary"))
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(target.name)
                    .font(.subheadline)
                    .foregroundColor(Color("TextPrimary"))
                    .lineLimit(1)
                Text(target.ip)
                    .font(.footnote)
                    .foregroundColor(Color("TextSecondary"))

                if !status.0.isEmpty {
                    Text(status.0)
                        .font(.footnote)
                        .foregroundColor(status.1)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            button
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var button: some View {
        switch action {
        case .send:
            Button("Send", action: onTap)
                .buttonStyle(.bordered)
                .disabled(!enabled)
        case .stop:
            Button("Stop", role: .destructive, action: onTap)
                .buttonStyle(.bordered)
        case .inFlight:
            ProgressView()
        }
    }
}

#endif
