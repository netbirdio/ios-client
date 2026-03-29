//
//  NetBirdApp.swift
//  NetBird
//
//  Created by Pascal Fischer on 01.08.23.
//
//  Main entry point for the NetBird app.
//  Supports both iOS and tvOS platforms.
//

import SwiftUI
import FirebaseCore
import Combine

#if os(iOS)
import FirebasePerformance
#endif

#if os(iOS)
class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        if let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
           let options = FirebaseOptions(contentsOfFile: path) {
            FirebaseApp.configure(options: options)
        }
        return true
    }
}
#endif

@main
struct NetBirdApp: App {
    @StateObject private var viewModelLoader = ViewModelLoader()
    @Environment(\.scenePhase) var scenePhase
    @State private var activationTask: Task<Void, Never>?

    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    #endif

    init() {
        // Configure Firebase on main thread as required by Firebase
        #if os(tvOS)
        if let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
           let options = FirebaseOptions(contentsOfFile: path) {
            FirebaseApp.configure(options: options)
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            if let viewModel = viewModelLoader.viewModel {
                MainView()
                    .environmentObject(viewModel)
                    #if os(iOS)
                    .onOpenURL { url in
                        handleWidgetURL(url, viewModel: viewModel)
                    }
                    .onAppear {
                        if UIApplication.shared.applicationState == .active {
                            startActivation(viewModel: viewModel)
                        }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                        startActivation(viewModel: viewModel)
                    }
                    .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                        stopActivation(viewModel: viewModel)
                    }
                    #endif
                    #if os(tvOS)
                    .onAppear {
                        if scenePhase == .active {
                            startActivation(viewModel: viewModel)
                        }
                    }
                    .onChange(of: scenePhase) { _, newPhase in
                        if newPhase == .active {
                            startActivation(viewModel: viewModel)
                        } else {
                            stopActivation(viewModel: viewModel)
                        }
                    }
                    #endif
            } else {
                loadingView
            }
        }
    }

    // MARK: - Activation

    private func startActivation(viewModel: ViewModel) {
        activationTask?.cancel()
        activationTask = Task { @MainActor in
            guard isAppActive else { return }

            if let initialStatus = await viewModel.networkExtensionAdapter.loadCurrentConnectionState() {
                viewModel.extensionState = initialStatus
                viewModel.updateVPNDisplayState()
            }

            guard isAppActive else { return }
            viewModel.checkExtensionState()
            #if os(iOS)
            viewModel.checkLoginRequiredFlag()
            #endif
            viewModel.startPollingDetails()
        }
    }

    private func stopActivation(viewModel: ViewModel) {
        activationTask?.cancel()
        activationTask = nil
        viewModel.stopPollingDetails()
    }

    private var isAppActive: Bool {
        #if os(iOS)
        UIApplication.shared.applicationState == .active
        #else
        scenePhase == .active
        #endif
    }

    private var loadingView: some View {
        ZStack {
            Color("BgPrimary")
                .ignoresSafeArea()
            Image("netbird-logo-menu")
                .resizable()
                .scaledToFit()
                .frame(width: 200)
        }
    }

    #if os(iOS)
    /// Handles deep link URLs from the Home Screen widget.
    private func handleWidgetURL(_ url: URL, viewModel: ViewModel) {
        guard url.scheme == "netbird" else { return }
        switch url.host {
        case "connect":
            if viewModel.vpnDisplayState == .disconnected {
                viewModel.connect()
            }
        case "disconnect":
            if viewModel.vpnDisplayState == .connected {
                viewModel.close()
            }
        default:
            break
        }
    }
    #endif
}

/// Loads ViewModel asynchronously to avoid blocking app launch.
/// The Go runtime initialization (from NetBirdSDK) can take several seconds on cold start.
/// By creating the ViewModel in an async Task, the loading screen appears immediately
/// instead of showing a black screen.
@MainActor
class ViewModelLoader: ObservableObject {
    @Published var viewModel: ViewModel?

    init() {
        Task { @MainActor in
            self.viewModel = ViewModel()
        }
    }
}
