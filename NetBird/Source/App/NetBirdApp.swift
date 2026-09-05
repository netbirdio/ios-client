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
import WidgetKit
#endif

/// True when the app was launched solely to host unit tests. XCTest sets this
/// environment variable on the test host process.
private var isRunningUnitTests: Bool {
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
}

/// Configures Firebase from the bundled GoogleService-Info.plist.
///
/// Skipped under unit tests: the CI test plist is a dummy and
/// FirebaseApp.configure() raises an uncaught Objective-C exception on an
/// invalid app ID, aborting the test host before the runner can connect.
private func configureFirebaseIfNeeded() {
    guard !isRunningUnitTests else { return }
    if let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
       let options = FirebaseOptions(contentsOfFile: path) {
        FirebaseApp.configure(options: options)
    }
}

#if os(iOS)
extension Notification.Name {
    static let netbirdLoginNotificationTapped = Notification.Name("io.netbird.loginNotificationTapped")
}

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        configureFirebaseIfNeeded()

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([AppDelegate.fileDropOfferCategory()])
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
        handleFileDropResponse(response)
        completionHandler()
    }

    /// Accept and Decline on an incoming offer, so answering does not require
    /// opening the app first. The category lives here rather than in the
    /// extension: categories registered from a Network Extension are not
    /// reliably picked up by the system.
    private static func fileDropOfferCategory() -> UNNotificationCategory {
        let accept = UNNotificationAction(
            identifier: FileDropNotification.acceptAction,
            title: NSLocalizedString("file_drop_accept", value: "Accept", comment: ""),
            options: [])
        let decline = UNNotificationAction(
            identifier: FileDropNotification.declineAction,
            title: NSLocalizedString("file_drop_decline", value: "Decline", comment: ""),
            options: [.destructive])

        return UNNotificationCategory(
            identifier: FileDropNotification.offerCategory,
            actions: [accept, decline],
            intentIdentifiers: [],
            options: [])
    }

    private func handleFileDropResponse(_ response: UNNotificationResponse) {
        let verb: String
        switch response.actionIdentifier {
        case FileDropNotification.acceptAction:
            verb = "Accept"
        case FileDropNotification.declineAction:
            verb = "Decline"
        default:
            return
        }

        guard let id = response.notification.request.content
            .userInfo[FileDropNotification.transferIDKey] as? String, !id.isEmpty else { return }

        DispatchQueue.main.async {
            FilesViewModel.shared.answerFromNotification(verb: verb, id: id)
        }
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
        configureFirebaseIfNeeded()
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
                        // Bound as early as the view model exists, so an answer
                        // queued by a notification action is released before the
                        // Files tab is ever opened.
                        FilesViewModel.shared.bind(adapter: viewModel.networkExtensionAdapter)
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
                // Clear stale button-press flags before applying the fresh NE state.
                // These flags are only valid for the brief gap between a button tap and
                // the corresponding NE state change; any external change (widget action,
                // On Demand trigger) makes them stale when returning to the foreground.
                viewModel.connectPressed = false
                viewModel.disconnectPressed = false
                viewModel.extensionState = initialStatus
                viewModel.updateVPNDisplayState()

                // Assigning extensionState directly means the checkExtensionState() below
                // hits applyExtensionStatus' `extensionState != status` guard and returns
                // early — taking its route side effects with it. Apply them here instead.
                //
                // Launching (or foregrounding) onto an already-connected tunnel would
                // otherwise leave the exit node selector stuck on "No exit nodes
                // available" until the user visits the Resources tab, whose own onAppear
                // does the fetch. Foregrounding onto a tunnel that dropped while the app
                // was away is the mirror case: the routes are never cleared, so the
                // selector stays enabled over nodes the core can no longer apply.
                //
                // loadCurrentConnectionState can await past this activation's lifetime:
                // its 200 ms retry sleep uses `try?`, which swallows cancellation. The
                // assignment above is a cheap local update, but the route sync below is
                // an IPC round-trip — don't make it for an activation already superseded.
                guard isAppActive, !Task.isCancelled else { return }
                viewModel.applyRouteSideEffects(for: initialStatus)
            } else {
                // No matching VPN profile found — still force a widget timeline refresh so
                // the widget doesn't stay stuck on a transitioning state from a prior
                // widget-initiated disconnect/connect while the app was closed.
                #if os(iOS)
                WidgetCenter.shared.reloadAllTimelines()
                #endif
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
