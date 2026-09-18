//
//  SSHTerminalView.swift
//  NetBird
//
//  The SSH terminal: xterm.js in a WKWebView, the key bar below it, and the
//  prompts a session can pause on. Mirrors the Android client's terminal
//  screen, including when the screen clears, when it does not, and what each
//  state prints.
//
//  The session itself belongs to `SSHSessionRegistry`, so dismissing this view
//  leaves the connection running and re-opening it replays the scrollback.
//

import SwiftUI
import WebKit

#if os(iOS)

struct SSHTerminalView: View {
    let sessionID: String

    @ObservedObject private var registry = SSHSessionRegistry.shared
    @Environment(\.presentationMode) private var presentationMode

    @StateObject private var terminal = SSHTerminalController()

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                SSHTerminalWebView(controller: terminal)
                    .background(Color.black)

                if terminal.showsReconnectBar {
                    reconnectBar
                }

                SSHKeyboardAccessoryView(
                    ctrlArmed: terminal.ctrlArmed,
                    altArmed: terminal.altArmed,
                    onKey: { terminal.send($0) },
                    onCursor: { terminal.sendCursorKey($0) },
                    onToggleCtrl: { terminal.toggleCtrl() },
                    onToggleAlt: { terminal.toggleAlt() },
                    onCopy: { terminal.copySelection() },
                    onPaste: { terminal.pasteClipboard() }
                )
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(terminal.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    // Leaves the session running, as backing out of the Android
                    // terminal does; the list still offers Disconnect.
                    Button("Done") { presentationMode.wrappedValue.dismiss() }
                }
            }
        }
        .onAppear { terminal.bind(sessionID: sessionID, registry: registry) }
        .onDisappear { terminal.unbind() }
        .sheet(isPresented: $terminal.showsPasswordPrompt) {
            SSHPasswordPrompt(
                target: terminal.target,
                rejected: terminal.passwordRejected,
                onSubmit: { terminal.submitPassword($0) },
                onCancel: { terminal.cancelPrompt() }
            )
        }
        .sheet(isPresented: $terminal.showsHostKeyPrompt) {
            SSHHostKeyPrompt(
                target: terminal.target,
                fingerprint: terminal.hostKeyFingerprint,
                onTrust: { terminal.trustHostKey() },
                onCancel: { terminal.cancelPrompt() }
            )
        }
        .toast(terminal.toast)
    }

    private var reconnectBar: some View {
        HStack(spacing: 10) {
            Text(terminal.reconnectMessage)
                .font(.system(size: 14))
                .foregroundColor(Color(white: 0.90))
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Reconnect") { terminal.reconnect() }
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.orange)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(red: 0.16, green: 0.13, blue: 0.09))
    }
}

// MARK: - Controller

/// Owns the web view bridge and the terminal-side state for one session.
/// Separate from the session handle on purpose: the session outlives this
/// screen, the xterm instance does not.
@MainActor
final class SSHTerminalController: ObservableObject, SSHSessionListener {

    @Published var showsReconnectBar = false
    @Published var reconnectMessage = ""
    @Published var showsPasswordPrompt = false
    @Published var passwordRejected = false
    @Published var showsHostKeyPrompt = false
    @Published var hostKeyFingerprint = ""
    @Published var ctrlArmed = false
    @Published var altArmed = false
    @Published var toast: String?

    private(set) var title = "SSH"
    private(set) var target = ""

    fileprivate weak var webView: WKWebView?
    private weak var registry: SSHSessionRegistry?
    private var sessionID: String?
    private var handle: SSHSessionHandle? {
        guard let sessionID else { return nil }
        return registry?.handle(id: sessionID)
    }

    /// Set once xterm has reported its size; nothing may be written before.
    private var terminalReady = false
    private var pendingSize: (cols: Int, rows: Int)?

    func bind(sessionID: String, registry: SSHSessionRegistry) {
        self.sessionID = sessionID
        self.registry = registry
        guard let handle = registry.handle(id: sessionID) else {
            printStatus("Session not found (it may have been closed).")
            return
        }
        title = handle.target
        target = handle.target
        handle.attach(self)
        // xterm can report ready before this view's onAppear runs, in which
        // case terminalDidBecomeReady found no session to act on. Replay it
        // here with the size it reported.
        if terminalReady, let size = pendingSize {
            startIfIdle(handle: handle, cols: size.cols, rows: size.rows)
        }
    }

    func unbind() {
        handle?.detach(self)
    }

    // MARK: Web view bridge

    func terminalDidBecomeReady(cols: Int, rows: Int) {
        terminalReady = true
        pendingSize = (cols, rows)
        guard let handle else {
            printStatus("Session not found (it may have been closed).")
            return
        }
        startIfIdle(handle: handle, cols: cols, rows: rows)
    }

    /// Dials a session that has never been connected. A session restored from
    /// the store arrives closed with nothing to replay, and this is where it
    /// gets its first dial, now that the grid size is known. One that is already
    /// dialling, connected, or closed with output to read is left alone: the
    /// reconnect bar is what redials those.
    private func startIfIdle(handle: SSHSessionHandle, cols: Int, rows: Int) {
        handle.resize(cols: cols, rows: rows)
        guard handle.state == .closed,
              !handle.hasScrollback,
              handle.stateMessage.isEmpty,
              !handle.hasEverConnected else { return }
        handle.open(cols: cols, rows: rows)
    }

    func terminalDidResize(cols: Int, rows: Int) {
        pendingSize = (cols, rows)
        handle?.resize(cols: cols, rows: rows)
    }

    /// Input from xterm. An armed Ctrl folds a letter into its control code, as
    /// a hardware keyboard would.
    func terminalDidInput(_ text: String) {
        var payload = Data(text.utf8)
        if ctrlArmed, payload.count == 1 {
            let b = payload[0]
            if b >= UInt8(ascii: "a"), b <= UInt8(ascii: "z") {
                payload = Data([b - UInt8(ascii: "a") + 1])
            } else if b >= UInt8(ascii: "A"), b <= UInt8(ascii: "Z") {
                payload = Data([b - UInt8(ascii: "A") + 1])
            }
            ctrlArmed = false
            syncModifierArmed()
        }
        send(payload)
    }

    // MARK: Keys

    /// Sends bytes, applying an armed Alt as the ESC prefix a terminal expects.
    func send(_ data: Data) {
        guard !data.isEmpty else { return }
        var payload = data
        if altArmed {
            payload = Data([0x1b]) + payload
            altArmed = false
            syncModifierArmed()
        }
        handle?.write(payload)
    }

    /// Arrow keys go through the page rather than straight to the session: only
    /// xterm knows whether the application asked for application cursor keys
    /// mode, and the sequence differs between the two. The page routes the
    /// chosen sequence back through the input bridge, so armed modifiers apply
    /// the same way as to typed characters.
    func sendCursorKey(_ ch: Character) {
        evaluate("window.sendCursorKey('\(ch)');")
    }

    func toggleCtrl() {
        ctrlArmed.toggle()
        syncModifierArmed()
    }

    func toggleAlt() {
        altArmed.toggle()
        syncModifierArmed()
    }

    /// Mirrors the armed state into the page, which needs it to know when a
    /// letter must be pulled out of a keyboard's pending word composition
    /// instead of waiting for a commit that may never come.
    private func syncModifierArmed() {
        evaluate("window.setModifierArmed(\(ctrlArmed || altArmed));")
    }

    func copySelection() {
        webView?.evaluateJavaScript("window.getTerminalSelection ? window.getTerminalSelection() : ''") { [weak self] value, _ in
            Task { @MainActor in
                guard let self else { return }
                guard let text = value as? String, !text.isEmpty else {
                    self.show(toast: "Select text in the terminal first")
                    return
                }
                UIPasteboard.general.string = text
                self.show(toast: "Copied to clipboard")
            }
        }
    }

    /// Sends the clipboard text through xterm's paste path so bracketed paste
    /// is honoured when the remote program asked for it.
    func pasteClipboard() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            show(toast: "Clipboard is empty")
            return
        }
        guard let encoded = try? JSONEncoder().encode(text),
              let literal = String(data: encoded, encoding: .utf8) else { return }
        evaluate("window.pasteText(\(literal));")
    }

    // MARK: Prompts

    func submitPassword(_ password: String) {
        showsPasswordPrompt = false
        handle?.retryWithPassword(password)
    }

    func trustHostKey() {
        showsHostKeyPrompt = false
        handle?.retryWithHostKeyTrust(hostKeyFingerprint)
    }

    /// Cancelling ends the session; otherwise it would be parked waiting for an
    /// answer with no way forward.
    func cancelPrompt() {
        showsPasswordPrompt = false
        showsHostKeyPrompt = false
        handle?.cancelPrompt()
    }

    func reconnect() {
        guard let sessionID, let registry else { return }
        let size = pendingSize
        if !registry.reconnect(id: sessionID, cols: size?.cols, rows: size?.rows) {
            printStatus("NetBird is not running")
        }
    }

    // MARK: SSHSessionListener

    nonisolated func sshSessionDidReplayScrollback(_ data: Data) {
        Task { @MainActor in
            self.clearTerminal()
            self.write(data)
        }
    }

    nonisolated func sshSessionDidReceive(_ data: Data) {
        Task { @MainActor in self.write(data) }
    }

    nonisolated func sshSessionDidChangeState(_ state: SSHSessionState, message: String) {
        Task { @MainActor in self.apply(state: state, message: message) }
    }

    private func apply(state: SSHSessionState, message: String) {
        switch state {
        case .connecting:
            // A reconnect starts here rather than in the create path, so this
            // is the only notice the user gets for it.
            if let handle { printStatus("Connecting to \(handle.target) …") }
            showsReconnectBar = false

        case .connected:
            // Drop the connect chatter so the prompt starts clean, but only on
            // the very first connect: a reconnect keeps the earlier output so
            // it stays scrollable, and a re-attach would otherwise wipe the
            // history it just restored.
            if terminalReady, let handle, !handle.hasEverConnected {
                clearTerminal()
            }
            showsReconnectBar = false

        case .needsPassword:
            guard !showsPasswordPrompt else { return }
            passwordRejected = !message.isEmpty
            // Only a rejection is worth a terminal line, since it stays
            // readable in the scrollback afterwards. The plain request needs
            // none: the prompt on screen already says it.
            if passwordRejected { printStatus("Wrong password") }
            showsHostKeyPrompt = false
            showsPasswordPrompt = true

        case .needsHostKeyConfirm:
            guard !showsHostKeyPrompt else { return }
            hostKeyFingerprint = message
            showsPasswordPrompt = false
            showsHostKeyPrompt = true

        case .closed:
            let text = message.isEmpty ? "Session closed" : "Session closed: \(message)"
            printStatus(text)
            reconnectMessage = text
            showsReconnectBar = true

        case .error:
            let text = "Error: \(message)"
            printStatus(text)
            reconnectMessage = text
            showsReconnectBar = true
        }
    }

    // MARK: Terminal writes

    private func write(_ data: Data) {
        evaluate("window.writeFromHost('\(data.base64EncodedString())');")
    }

    private func clearTerminal() {
        evaluate("window.resetTerminal && window.resetTerminal();")
    }

    /// Server errors arrive with newlines in them, which a hand-rolled escape
    /// turns into a broken statement that drops the status line entirely, so
    /// the text is JSON-encoded rather than quoted by hand.
    private func printStatus(_ text: String) {
        guard let encoded = try? JSONEncoder().encode(text),
              let literal = String(data: encoded, encoding: .utf8) else { return }
        evaluate("window.printStatus(\(literal));")
    }

    private func evaluate(_ script: String) {
        webView?.evaluateJavaScript(script)
    }

    private func show(toast message: String) {
        toast = message
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if toast == message { toast = nil }
        }
    }
}

// MARK: - Web view

/// Hosts xterm.js in a WKWebView and bridges it to the controller.
/// JS -> Swift: WKScriptMessageHandler ("terminalReady", "terminalInput", "terminalResize").
/// Swift -> JS: evaluateJavaScript against the `window.*` functions terminal.html defines.
private struct SSHTerminalWebView: UIViewRepresentable {
    let controller: SSHTerminalController

    func makeUIView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()
        for name in ["terminalReady", "terminalInput", "terminalResize"] {
            contentController.add(context.coordinator, name: name)
        }

        let config = WKWebViewConfiguration()
        config.userContentController = contentController

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = false
        webView.backgroundColor = .black
        // The page handles the keyboard inset itself by refitting xterm to the
        // shrunken view; letting the web view scroll instead would slide the
        // grid out from under the cursor.
        webView.scrollView.isScrollEnabled = false

        if let url = Bundle.main.url(forResource: "terminal", withExtension: "html", subdirectory: "Terminal") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }

        controller.webView = webView
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        // Script handlers retain the coordinator, which retains the controller;
        // without this the whole terminal leaks on every dismissal.
        for name in ["terminalReady", "terminalInput", "terminalResize"] {
            uiView.configuration.userContentController.removeScriptMessageHandler(forName: name)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        private let controller: SSHTerminalController

        init(controller: SSHTerminalController) {
            self.controller = controller
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            switch message.name {
            case "terminalReady":
                guard let cols = body["cols"] as? Int, let rows = body["rows"] as? Int else { return }
                Task { @MainActor in controller.terminalDidBecomeReady(cols: cols, rows: rows) }

            case "terminalInput":
                guard let text = body["data"] as? String else { return }
                Task { @MainActor in controller.terminalDidInput(text) }

            case "terminalResize":
                guard let cols = body["cols"] as? Int, let rows = body["rows"] as? Int else { return }
                Task { @MainActor in controller.terminalDidResize(cols: cols, rows: rows) }

            default:
                break
            }
        }
    }
}

// MARK: - Prompts

/// Asks for a password once the server has told us the NetBird key is not
/// enough. Reached only from the `needsPassword` state.
private struct SSHPasswordPrompt: View {
    let target: String
    let rejected: Bool
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var password = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationView {
            Form {
                Section {
                    SecureField("Password", text: $password)
                        .focused($focused)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit { onSubmit(password) }
                } header: {
                    // The title says what is being asked, so this line only has
                    // to name the target. A rejection replaces it, because the
                    // reason matters more than repeating the target.
                    Text(rejected ? "The password was rejected. Try again." : target)
                }
            }
            .navigationTitle("Password required")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") { onSubmit(password) }
                }
            }
        }
        .onAppear { focused = true }
    }
}

/// Shows the presented host-key fingerprint for a regular server and, on
/// confirmation, retries with it trusted. Only regular (non-NetBird) servers
/// reach this: NetBird peers verify against the peer registry.
private struct SSHHostKeyPrompt: View {
    let target: String
    let fingerprint: String
    let onTrust: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationView {
            Form {
                Section {
                    // Selectable so the value can be compared out of band.
                    Text(fingerprint)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundColor(Color("TextPrimary"))
                        .textSelection(.enabled)
                } header: {
                    Text("The server \(target) is not yet trusted. Verify its fingerprint before connecting:")
                        .textCase(nil)
                }
            }
            .navigationTitle("Unknown host key")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Trust", action: onTrust)
                }
            }
        }
    }
}

// MARK: - Toast

private struct ToastModifier: ViewModifier {
    let message: String?

    func body(content: Content) -> some View {
        ZStack {
            content
            if let message {
                VStack {
                    Spacer()
                    Text(message)
                        .font(.footnote)
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Color.black.opacity(0.8)))
                        .padding(.bottom, 120)
                }
                .transition(.opacity)
                .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: message)
    }
}

extension View {
    func toast(_ message: String?) -> some View {
        modifier(ToastModifier(message: message))
    }
}

#endif
