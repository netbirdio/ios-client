//
//  iOSFilesView.swift
//  NetBird
//
//  Files tab: incoming offers awaiting consent pinned to the top, then the
//  transfer log grouped by day, newest first. The receiving policy is not
//  here; it lives under Settings, so this screen stays a log.
//

import SwiftUI

#if os(iOS)

struct iOSFilesView: View {
    @EnvironmentObject var viewModel: ViewModel
    @StateObject private var filesVM = FilesViewModel()

    @State private var showSendSheet = false
    @State private var shareItems: [Any]? = nil
    @State private var confirmAction: FilesConfirmAction? = nil
    @State private var showCopiedToast = false

    var body: some View {
        ZStack {
            Color("BgMenu")
                .ignoresSafeArea()

            content
                .sheet(isPresented: Binding(
                    get: { shareItems != nil },
                    set: { if !$0 { shareItems = nil } }
                )) {
                    if let items = shareItems {
                        FileActivityView(items: items)
                    }
                }

            if showCopiedToast {
                copiedToast
            }
        }
        .navigationTitle("Files")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showSendSheet = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .searchable(text: $filesVM.searchText, prompt: "Search by file or peer")
        .sheet(isPresented: $showSendSheet) {
            FileSendView(filesVM: filesVM)
                .environmentObject(viewModel)
        }
        .alert(item: $confirmAction) { action in
            switch action {
            case .stop(let transfer):
                return Alert(
                    title: Text("Stop transfer"),
                    message: Text("Stop this transfer? It stays in the list so you can remove it afterwards."),
                    primaryButton: .destructive(Text("Stop")) {
                        filesVM.stop(transfer)
                    },
                    secondaryButton: .cancel()
                )
            case .remove(let transfer):
                return Alert(
                    title: Text("Remove transfer"),
                    message: Text("Remove this transfer from the list?"),
                    primaryButton: .destructive(Text("Remove")) {
                        filesVM.remove(transfer)
                    },
                    secondaryButton: .cancel()
                )
            }
        }
        .onAppear {
            filesVM.bind(adapter: viewModel.networkExtensionAdapter)
            filesVM.startPolling()
        }
        .onDisappear {
            filesVM.stopPolling()
        }
    }

    @ViewBuilder
    private var content: some View {
        if filesVM.filteredTransfers.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "arrow.up.arrow.down.circle")
                    .font(.system(size: 40))
                    .foregroundColor(Color("TextSecondary"))
                Text(filesVM.searchText.isEmpty ? "No transfers yet" : "No matching transfers")
                    .foregroundColor(Color("TextSecondary"))
            }
        } else {
            List {
                if !filesVM.pendingOffers.isEmpty {
                    Section(header: Text("Incoming")) {
                        ForEach(filesVM.pendingOffers) { offer in
                            FileOfferRow(offer: offer,
                                         onAccept: { filesVM.accept(offer) },
                                         onDecline: { filesVM.decline(offer) })
                        }
                    }
                }

                ForEach(filesVM.dayGroups, id: \.label) { group in
                    Section(header: Text(group.label)) {
                        ForEach(group.items) { transfer in
                            FileTransferRow(transfer: transfer)
                                .contentShape(Rectangle())
                                .contextMenu { rowActions(for: transfer) }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        confirmAction = .remove(transfer)
                                    } label: {
                                        Label("Remove", systemImage: "trash")
                                    }
                                }
                        }
                    }
                }
            }
            .listStyle(InsetGroupedListStyle())
        }
    }

    @ViewBuilder
    private func rowActions(for transfer: FileDropTransferInfo) -> some View {
        if transfer.isText && !transfer.text.isEmpty {
            Button {
                UIPasteboard.general.string = transfer.text
                withAnimation { showCopiedToast = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    withAnimation { showCopiedToast = false }
                }
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }

        if !transfer.outgoing, transfer.transferState == .completed, !transfer.deliveredPaths.isEmpty {
            Button {
                shareItems = transfer.deliveredPaths.map { URL(fileURLWithPath: $0) }
            } label: {
                Label("Save or share", systemImage: "square.and.arrow.up")
            }
        }

        if !transfer.isTerminal {
            Button {
                confirmAction = .stop(transfer)
            } label: {
                Label("Stop", systemImage: "stop.circle")
            }
        }

    }

    private var copiedToast: some View {
        VStack {
            Spacer()
            Text("Copied")
                .foregroundColor(.white)
                .font(.headline)
                .padding(8)
                .background(Color.black.opacity(0.5))
                .cornerRadius(8)
            Spacer().frame(height: 80)
        }
        .transition(AnyTransition.opacity.combined(with: .move(edge: .bottom)))
        .zIndex(1)
    }
}

enum FilesConfirmAction: Identifiable {
    case stop(FileDropTransferInfo)
    case remove(FileDropTransferInfo)

    var id: String {
        switch self {
        case .stop(let t): return "stop-\(t.id)"
        case .remove(let t): return "remove-\(t.id)"
        }
    }
}

// MARK: - Rows

struct FileOfferRow: View {
    let offer: FileDropTransferInfo
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(FileDropFormat.title(for: offer))
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Color("TextPrimary"))
                .lineLimit(2)

            Text("\(offer.peerName) wants to send this")
                .font(.system(size: 14))
                .foregroundColor(Color("TextSecondary"))

            HStack(spacing: 12) {
                Button(action: onAccept) {
                    Text("Accept")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
                .buttonStyle(PlainButtonStyle())

                Button(action: onDecline) {
                    Text("Decline")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color("BgPeerCard"))
                        .foregroundColor(Color("TextPrimary"))
                        .cornerRadius(8)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.vertical, 4)
    }
}

struct FileTransferRow: View {
    let transfer: FileDropTransferInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                Image(systemName: transfer.isText ? "text.quote" : (transfer.outgoing ? "arrow.up.doc" : "arrow.down.doc"))
                    .foregroundColor(.accentColor)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(FileDropFormat.title(for: transfer))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(Color("TextPrimary"))
                        .lineLimit(2)

                    Text(FileDropFormat.subtitle(for: transfer))
                        .font(.system(size: 13))
                        .foregroundColor(Color("TextSecondary"))
                }

                Spacer()

                Text(FileDropFormat.outcome(for: transfer))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(FileDropFormat.outcomeColor(for: transfer))
            }

            if transfer.transferState == .transferring, transfer.totalSize > 0 {
                ProgressView(value: Double(transfer.transferred), total: Double(transfer.totalSize))
                    .padding(.leading, 32)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Labels

enum FileDropFormat {

    static func title(for transfer: FileDropTransferInfo) -> String {
        if transfer.isText {
            let text = transfer.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\u{201C}\(text)\u{201D}"
        }
        if transfer.fileNames.count > 1 {
            return "\(transfer.fileNames[0]) + \(transfer.fileNames.count - 1) more"
        }
        return transfer.fileNames.first ?? "File"
    }

    static func subtitle(for transfer: FileDropTransferInfo) -> String {
        let direction = transfer.outgoing ? "to \(transfer.peerName)" : "from \(transfer.peerName)"
        var parts = [direction]
        if !transfer.isText, transfer.totalSize > 0 {
            parts.append(size(transfer.totalSize))
        }
        if let created = transfer.createdAt {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            parts.append(formatter.string(from: created))
        }
        return parts.joined(separator: " · ")
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Matches the desktop's wording: an unreachable send reads as declined,
    /// since the sender only learns that nothing answered.
    static func outcome(for transfer: FileDropTransferInfo) -> String {
        if transfer.isUnreachable {
            return "Declined"
        }
        switch transfer.transferState {
        case .pending:
            return "Waiting"
        case .transferring:
            if transfer.totalSize <= 0 {
                return "Transferring"
            }
            let percent = Int(transfer.transferred * 100 / transfer.totalSize)
            return transfer.outgoing ? "Sending \(percent)%" : "Receiving \(percent)%"
        case .completed:
            return transfer.outgoing ? "Sent" : "Received"
        case .declined:
            return "Declined"
        case .expired:
            return "No response"
        case .cancelled:
            return "Cancelled"
        case .failed:
            return "Failed"
        }
    }

    /// Colours only what the eye should catch scanning the outcome column: a
    /// refusal or failure in red, a completed send in green. Everything else
    /// stays neutral so the exceptions stand out.
    static func outcomeColor(for transfer: FileDropTransferInfo) -> Color {
        if transfer.isUnreachable {
            return .red
        }
        switch transfer.transferState {
        case .declined, .failed:
            return .red
        case .completed where transfer.outgoing:
            return .green
        default:
            return Color("TextSecondary")
        }
    }
}

struct FileActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#endif
