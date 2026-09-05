//
//  iOSFilesView.swift
//  NetBird
//
//  Files tab: incoming offers awaiting consent pinned to the top, then the
//  transfer log grouped by day, newest first. The receiving policy is not
//  here; it lives under Settings, so this screen stays a log.
//
//  The structure mirrors the Android screen, the interaction does not: a tap
//  previews a received file, the row's own actions live in swipe actions, and
//  the destructive ones ask through a confirmation dialog.
//

import SwiftUI
import QuickLook

#if os(iOS)

struct iOSFilesView: View {
    @EnvironmentObject var viewModel: ViewModel
    @ObservedObject private var filesVM = FilesViewModel.shared

    @State private var showSendSheet = false
    @State private var shareItems: [Any]? = nil
    @State private var previewURLs: FilePreviewRequest? = nil
    @State private var confirmAction: FilesConfirmAction? = nil

    var body: some View {
        content
            .navigationTitle("Files")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showSendSheet = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Send files")
                }
            }
            .searchable(text: $filesVM.searchText, prompt: "Search by file or peer")
            .refreshable {
                filesVM.refresh()
            }
            .sheet(isPresented: $showSendSheet) {
                FileSendView(filesVM: filesVM)
                    .environmentObject(viewModel)
            }
            .sheet(item: $previewURLs) { request in
                FilePreviewView(urls: request.urls)
            }
            .sheet(isPresented: Binding(
                get: { shareItems != nil },
                set: { if !$0 { shareItems = nil } }
            )) {
                if let items = shareItems {
                    FileActivityView(items: items)
                }
            }
            .confirmationDialog(
                confirmAction?.title ?? "",
                isPresented: Binding(
                    get: { confirmAction != nil },
                    set: { if !$0 { confirmAction = nil } }
                ),
                titleVisibility: .visible,
                presenting: confirmAction
            ) { action in
                switch action {
                case .stop(let transfer):
                    Button("Stop", role: .destructive) { filesVM.stop(transfer) }
                case .remove(let transfer):
                    Button("Remove", role: .destructive) { filesVM.remove(transfer) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { action in
                Text(action.message)
            }
            .onAppear {
                filesVM.bind(adapter: viewModel.networkExtensionAdapter)
                filesVM.startPolling()
            }
            .onDisappear {
                filesVM.stopPolling()
            }
    }

    // MARK: - List

    /// The empty state is a row inside the list rather than a view replacing
    /// it, so the search field keeps its place while a query matches nothing.
    private var content: some View {
        List {
            if filesVM.filteredTransfers.isEmpty {
                emptyRow
            } else {
                if !filesVM.pendingOffers.isEmpty {
                    Section(header: Text("Incoming")) {
                        ForEach(filesVM.pendingOffers) { offer in
                            FileOfferRow(offer: offer,
                                         onAccept: { answer(offer, accept: true) },
                                         onDecline: { answer(offer, accept: false) })
                        }
                    }
                }

                ForEach(filesVM.dayGroups, id: \.label) { group in
                    Section(header: Text(group.label)) {
                        ForEach(group.items) { transfer in
                            row(for: transfer)
                        }
                    }
                }
            }
        }
        .listStyle(InsetGroupedListStyle())
    }

    private var emptyRow: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.up.arrow.down.circle")
                .font(.largeTitle)
                .foregroundColor(Color("TextSecondary"))
            Text(filesVM.searchText.isEmpty ? "No transfers yet" : "No matching transfers")
                .font(.subheadline)
                .foregroundColor(Color("TextSecondary"))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    /// A received file opens on tap, which is the row's primary action; the
    /// rest hangs off swipe actions, with the context menu repeating them for
    /// discovery rather than being the only way in.
    @ViewBuilder
    private func row(for transfer: FileDropTransferInfo) -> some View {
        FileTransferRow(transfer: transfer)
            .contentShape(Rectangle())
            .onTapGesture { open(transfer) }
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                if transfer.isText && !transfer.text.isEmpty {
                    Button {
                        copy(transfer)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .tint(.accentColor)
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    confirmAction = .remove(transfer)
                } label: {
                    Label("Remove", systemImage: "trash")
                }

                if !transfer.isTerminal {
                    Button {
                        confirmAction = .stop(transfer)
                    } label: {
                        Label("Stop", systemImage: "stop.circle")
                    }
                }
            }
            .contextMenu { rowActions(for: transfer) }
    }

    @ViewBuilder
    private func rowActions(for transfer: FileDropTransferInfo) -> some View {
        if transfer.isText && !transfer.text.isEmpty {
            Button {
                copy(transfer)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }

        if filesVM.isPreviewable(transfer) {
            Button {
                open(transfer)
            } label: {
                Label("Preview", systemImage: "eye")
            }

            Button {
                shareItems = filesVM.deliveredURLs(for: transfer)
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

        Button(role: .destructive) {
            confirmAction = .remove(transfer)
        } label: {
            Label("Remove", systemImage: "trash")
        }
    }

    // MARK: - Actions

    private func open(_ transfer: FileDropTransferInfo) {
        let urls = filesVM.deliveredURLs(for: transfer)
        guard filesVM.isPreviewable(transfer), !urls.isEmpty else { return }
        previewURLs = FilePreviewRequest(id: transfer.id, urls: urls)
    }

    /// No toast: the pasteboard write is silent on iOS, and a haptic tick is
    /// the platform's own way of saying it landed.
    private func copy(_ transfer: FileDropTransferInfo) {
        guard transfer.isText, !transfer.text.isEmpty else { return }
        UIPasteboard.general.string = transfer.text
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func answer(_ offer: FileDropTransferInfo, accept: Bool) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if accept {
            filesVM.accept(offer)
        } else {
            filesVM.decline(offer)
        }
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

    var title: String {
        switch self {
        case .stop(let t): return FileDropFormat.title(for: t)
        case .remove(let t): return FileDropFormat.title(for: t)
        }
    }

    var message: LocalizedStringKey {
        switch self {
        case .stop:
            return "Stop this transfer? It stays in the list so you can remove it afterwards."
        case .remove:
            return "Remove this transfer from the list?"
        }
    }
}

/// A preview is addressed by the transfer it came from, so reopening the same
/// row does not present a stale set of URLs.
struct FilePreviewRequest: Identifiable {
    let id: String
    let urls: [URL]
}

// MARK: - Rows

struct FileOfferRow: View {
    let offer: FileDropTransferInfo
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(FileDropFormat.title(for: offer))
                .font(.headline)
                .foregroundColor(Color("TextPrimary"))
                .lineLimit(2)

            Text(FileDropFormat.offerSubtitle(for: offer))
                .font(.subheadline)
                .foregroundColor(Color("TextSecondary"))

            HStack(spacing: 12) {
                Button("Accept", action: onAccept)
                    .buttonStyle(.borderedProminent)

                Button("Decline", action: onDecline)
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 6)
    }
}

struct FileTransferRow: View {
    let transfer: FileDropTransferInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                // The icon column reads direction: outgoing in the brand
                // accent, incoming in green, as on the desktop and Android.
                Image(systemName: transfer.isText
                      ? "text.quote"
                      : (transfer.outgoing ? "arrow.up.doc" : "arrow.down.doc"))
                    .foregroundColor(transfer.outgoing ? .accentColor : Color(.systemGreen))
                    .frame(width: 24)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(FileDropFormat.title(for: transfer))
                        .font(.subheadline)
                        .foregroundColor(Color("TextPrimary"))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(FileDropFormat.peerLine(for: transfer))
                        .font(.footnote)
                        .foregroundColor(Color("TextSecondary"))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(FileDropFormat.metaLine(for: transfer))
                        .font(.footnote)
                        .foregroundColor(Color("TextSecondary"))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                // The outcome always keeps its place. Android hands this slot
                // to a copy button on text rows and the desktop overlays it on
                // hover; on a touch screen there is no hover to give it back,
                // so a failed snippet would simply lose its red label.
                Text(FileDropFormat.outcome(for: transfer))
                    .font(.footnote)
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
            let format = NSLocalizedString("file_drop_title_multiple", value: "%1$@ + %2$d more",
                                           comment: "first file name, count of the rest")
            return String(format: format, transfer.fileNames[0], transfer.fileNames.count - 1)
        }
        return transfer.fileNames.first
            ?? NSLocalizedString("file_drop_title_file", value: "File", comment: "")
    }

    static func offerSubtitle(for transfer: FileDropTransferInfo) -> String {
        let format = NSLocalizedString("file_drop_offer_subtitle", value: "%@ wants to send this",
                                       comment: "peer name")
        return String(format: format, transfer.peerName)
    }

    static func peerLine(for transfer: FileDropTransferInfo) -> String {
        let format = transfer.outgoing
            ? NSLocalizedString("file_drop_direction_sent", value: "to %@", comment: "peer name")
            : NSLocalizedString("file_drop_direction_received", value: "from %@", comment: "peer name")
        return String(format: format, transfer.peerName)
    }

    static func metaLine(for transfer: FileDropTransferInfo) -> String {
        var parts: [String] = []
        if let created = transfer.createdAt {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            parts.append(formatter.string(from: created))
        }
        if !transfer.isText, transfer.totalSize > 0 {
            parts.append(size(transfer.totalSize))
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
            return NSLocalizedString("file_drop_state_declined", value: "Declined", comment: "")
        }
        switch transfer.transferState {
        case .pending:
            return NSLocalizedString("file_drop_state_pending", value: "Waiting", comment: "")
        case .transferring:
            if transfer.totalSize <= 0 {
                return NSLocalizedString("file_drop_state_transferring", value: "Transferring", comment: "")
            }
            let percent = Int(transfer.transferred * 100 / transfer.totalSize)
            let format = transfer.outgoing
                ? NSLocalizedString("file_drop_state_progress", value: "Sending %d%%", comment: "percent")
                : NSLocalizedString("file_drop_state_progress_incoming", value: "Receiving %d%%", comment: "percent")
            return String(format: format, percent)
        case .completed:
            return transfer.outgoing
                ? NSLocalizedString("file_drop_state_sent", value: "Sent", comment: "")
                : NSLocalizedString("file_drop_state_received", value: "Received", comment: "")
        case .declined:
            return NSLocalizedString("file_drop_state_declined", value: "Declined", comment: "")
        case .expired:
            return NSLocalizedString("file_drop_state_expired", value: "No response", comment: "")
        case .cancelled:
            return NSLocalizedString("file_drop_state_cancelled", value: "Cancelled", comment: "")
        case .failed:
            return NSLocalizedString("file_drop_state_failed", value: "Failed", comment: "")
        }
    }

    /// The outcome column has its own legend, separate from the icon's: green
    /// is a transfer that arrived, either way round, red is one the far side
    /// refused or that broke, grey is everything else. A transfer in flight is
    /// grey too, the progress bar already says it is moving; tinting the label
    /// as well would hand the accent a second meaning next to the icon's.
    static func outcomeColor(for transfer: FileDropTransferInfo) -> Color {
        if transfer.isUnreachable {
            return Color(.systemRed)
        }
        switch transfer.transferState {
        case .completed:
            return Color(.systemGreen)
        case .declined, .failed:
            return Color(.systemRed)
        case .pending, .transferring, .cancelled, .expired:
            return Color("TextSecondary")
        }
    }
}

// MARK: - System presentations

/// QuickLook over the delivered copies. Wrapped in a navigation controller so
/// the preview arrives with the Done button a modal needs.
struct FilePreviewView: UIViewControllerRepresentable {
    let urls: [URL]

    func makeCoordinator() -> Coordinator {
        Coordinator(urls: urls)
    }

    func makeUIViewController(context: Context) -> UINavigationController {
        let preview = QLPreviewController()
        preview.dataSource = context.coordinator
        return UINavigationController(rootViewController: preview)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}

    class Coordinator: NSObject, QLPreviewControllerDataSource {
        private let urls: [URL]

        init(urls: [URL]) {
            self.urls = urls
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            urls.count
        }

        func previewController(_ controller: QLPreviewController,
                               previewItemAt index: Int) -> QLPreviewItem {
            urls[index] as QLPreviewItem
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
