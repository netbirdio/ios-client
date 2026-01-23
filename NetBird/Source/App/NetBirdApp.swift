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
                    .onAppear {
                        // Start polling when MainView appears.
                        // This handles the case where didBecomeActiveNotification fired
                        // before the ViewModel was ready (during async initialization).
                        #if os(iOS)
                        if UIApplication.shared.applicationState == .active {
                            viewModel.checkExtensionState()
                            viewModel.checkLoginRequiredFlag()
                            viewModel.startPollingDetails()
                        }
                        #else
                        // tvOS: scenePhase may not be reliable in onAppear, start polling directly
                        viewModel.checkExtensionState()
                        viewModel.startPollingDetails()
                        #endif
                    }
                    #if os(iOS)
                    .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                        print("App is active!")
                        activationTask?.cancel()
                        activationTask = Task { @MainActor in
                            guard UIApplication.shared.applicationState == .active else { return }
                            // Load existing VPN manager first to establish session for status polling.
                            // This must complete before polling starts to avoid returning default disconnected status
                            // when the VPN is actually connected.
                            if let initialStatus = await viewModel.networkExtensionAdapter.loadCurrentConnectionState() {
                                // Set the initial extension state immediately so the UI shows the correct status
                                viewModel.extensionState = initialStatus
                            }
                            guard UIApplication.shared.applicationState == .active else { return }
                            viewModel.checkExtensionState()
                            viewModel.checkLoginRequiredFlag()
                            viewModel.startPollingDetails()
                        }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                        print("App is inactive!")
                        activationTask?.cancel()
                        activationTask = nil
                        viewModel.stopPollingDetails()
                    }
                    #endif
                    #if os(tvOS)
                    .onChange(of: scenePhase) { _, newPhase in
                        switch newPhase {
                        case .active:
                            print("App is active!")
                            activationTask?.cancel()
                            activationTask = Task { @MainActor in
                                guard scenePhase == .active else { return }
                                // Load existing VPN manager first to establish session for status polling.
                                // This must complete before polling starts to avoid returning default disconnected status
                                // when the VPN is actually connected.
                                if let initialStatus = await viewModel.networkExtensionAdapter.loadCurrentConnectionState() {
                                    // Set the initial extension state immediately so the UI shows the correct status
                                    viewModel.extensionState = initialStatus
                                }
                                guard scenePhase == .active else { return }
                                viewModel.checkExtensionState()
                                viewModel.startPollingDetails()
                            }
                        case .inactive, .background:
                            print("App is inactive!")
                            activationTask?.cancel()
                            activationTask = nil
                            viewModel.stopPollingDetails()
                        @unknown default:
                            break
                        }
                    }
                    #endif
            } else {
                // Show loading screen while ViewModel initializes asynchronously.
                // This prevents a black screen during Go runtime initialization.
                ZStack {
                    Color("BgPrimary")
                        .ignoresSafeArea()
                    Image("netbird-logo-menu")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 200)
                }
            }
        }
    }
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
