//
//  SSHTerminalView.swift
//  NetBird
//

import SwiftUI
import WebKit
import Combine

struct SSHTerminalView: View {
    @ObservedObject var viewModel: SSHSessionViewModel
    @Environment(\.presentationMode) var presentationMode
    @State private var shouldFit = false
    @State private var copyRequest = false

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                ZStack(alignment: .top) {
                    SSHTerminalWebView(viewModel: viewModel, shouldFit: $shouldFit, copyRequest: $copyRequest)
                        .ignoresSafeArea(edges: .bottom)

                    if case .connecting = viewModel.state {
                        ProgressView("Connecting…")
                            .padding()
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                            .padding(.top, 24)
                    }
                }

                if viewModel.canReconnect {
                    reconnectBanner
                }

                SSHKeyboardAccessoryView(
                    onInput: { data in viewModel.write(data) },
                    onCopy: { copyRequest = true }
                )
            }
            .navigationTitle("\(viewModel.user)@\(viewModel.host)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Close") {
                        viewModel.stop()
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { shouldFit = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { shouldFit = true }
        }
    }

    private var reconnectBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.yellow)
            Text("Connection lost")
                .foregroundColor(.white)
                .font(.subheadline)
            Spacer()
            Button("Reconnect") {
                viewModel.reconnect()
            }
            .font(.subheadline.weight(.semibold))
            .foregroundColor(.accentColor)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.systemGray6).opacity(0.95))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// Hosts xterm.js in a WKWebView and bridges it to `SSHSessionViewModel`.
/// JS -> Swift: WKScriptMessageHandler ("terminalReady", "terminalInput", "terminalResize").
/// Swift -> JS: evaluateJavaScript calls into the `NBTerminal` object in terminal-bridge.js.
private struct SSHTerminalWebView: UIViewRepresentable {
    @ObservedObject var viewModel: SSHSessionViewModel
    @Binding var shouldFit: Bool
    @Binding var copyRequest: Bool

    func makeUIView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "terminalReady")
        contentController.add(context.coordinator, name: "terminalInput")
        contentController.add(context.coordinator, name: "terminalResize")

        let config = WKWebViewConfiguration()
        config.userContentController = contentController

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.bounces = false
        webView.isOpaque = false
        webView.backgroundColor = .black

        if let url = Bundle.main.url(forResource: "terminal", withExtension: "html", subdirectory: "Terminal") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }

        context.coordinator.webView = webView
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        if shouldFit {
            uiView.evaluateJavaScript("if(window.NBTerminal){NBTerminal.fit()}")
            DispatchQueue.main.async { shouldFit = false }
        }
        if copyRequest {
            uiView.evaluateJavaScript("window.NBTerminal ? NBTerminal.getSelection() : ''") { result, _ in
                if let text = result as? String, !text.isEmpty {
                    UIPasteboard.general.string = text
                }
            }
            DispatchQueue.main.async { copyRequest = false }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        let viewModel: SSHSessionViewModel
        weak var webView: WKWebView?
        private var cancellables = Set<AnyCancellable>()

        init(viewModel: SSHSessionViewModel) {
            self.viewModel = viewModel
            super.init()
            viewModel.onOutput = { [weak self] data in
                self?.write(data)
            }
            viewModel.$state
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] state in
                    switch state {
                    case .failed(let message):
                        self?.setStatus("Connection failed: \(message)", color: "red")
                    case .closed(let reason):
                        self?.setStatus("Session closed: \(reason)", color: "yellow")
                    default:
                        break
                    }
                }
                .store(in: &cancellables)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "terminalReady":
                guard let body = message.body as? [String: Any],
                      let cols = body["cols"] as? Int, let rows = body["rows"] as? Int else { return }
                viewModel.onTerminalReady(cols: cols, rows: rows)

            case "terminalInput":
                guard let body = message.body as? [String: Any],
                      let text = body["data"] as? String else { return }
                viewModel.write(Data(text.utf8))

            case "terminalResize":
                guard let body = message.body as? [String: Any],
                      let cols = body["cols"] as? Int, let rows = body["rows"] as? Int else { return }
                viewModel.resize(cols: cols, rows: rows)

            default:
                break
            }
        }

        private func write(_ data: Data) {
            let base64 = data.base64EncodedString()
            webView?.evaluateJavaScript("NBTerminal.write('\(base64)')")
        }

        private func setStatus(_ text: String, color: String) {
            let ansiColor = color == "red" ? "\u{1b}[31m" : "\u{1b}[33m"
            let js = "NBTerminal.write('\(Data((ansiColor + "\r\n" + text + "\r\n\u{1b}[0m").utf8).base64EncodedString())')"
            webView?.evaluateJavaScript(js)
        }
    }
}
