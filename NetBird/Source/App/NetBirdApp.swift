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
import UserNotifications
import NetBirdSDK

#if os(iOS)
import FirebasePerformance
#endif

#if os(iOS)
extension Notification.Name {
    static let netbirdLoginNotificationTapped = Notification.Name("io.netbird.loginNotificationTapped")
}

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        if let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
           let options = FirebaseOptions(contentsOfFile: path) {
            FirebaseApp.configure(options: options)
        }

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                AppLogger.shared.log("Notification authorization error: \(error.localizedDescription)")
            } else {
                AppLogger.shared.log("Notification authorization granted: \(granted)")
            }
        }

        return true
    }

    // Show notification banner even when app is in foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    // Handle tap on notification — post event so the app navigates to auth flow
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.notification.request.identifier == GlobalConstants.notificationLoginRequired {
            NotificationCenter.default.post(name: .netbirdLoginNotificationTapped, object: nil)
        }
        completionHandler()
    }
}
#endif

@main
struct NetBirdApp: App {
    @StateObject private var viewModelLoader = ViewModelLoader()
    @Environment(\.scenePhase) var scenePhase
    @State private var activationTask: Task<Void, Never>?
    @State private var pendingURL: URL?

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
                        if let url = pendingURL {
                            handleWidgetURL(url, viewModel: viewModel)
                            pendingURL = nil
                        }
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
                    .onReceive(NotificationCenter.default.publisher(for: .netbirdLoginNotificationTapped)) { _ in
                        viewModel.showAuthenticationRequired = true
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
                    #if os(iOS)
                    .onOpenURL { url in
                        pendingURL = url
                    }
                    #endif
            }
        }
    }

    // MARK: - Activation

    private func startActivation(viewModel: ViewModel) {
        activationTask?.cancel()
        activationTask = Task { @MainActor in
            guard isAppActive, !Task.isCancelled else { return }

            if let initialStatus = await viewModel.networkExtensionAdapter.loadCurrentConnectionState() {
                viewModel.extensionState = initialStatus
                viewModel.updateVPNDisplayState()
            }

            guard isAppActive, !Task.isCancelled else { return }
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
        case "login":
            viewModel.connect()
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
