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

// Firebase Performance is only available on iOS
#if os(iOS)
import FirebasePerformance
#endif

// App Delegate is iOS only
#if os(iOS)
class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Defer Firebase initialization to avoid blocking app startup
        // Firebase is used for analytics/crashlytics - not critical for initial UI display
        DispatchQueue.global(qos: .utility).async {
            if let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
               let options = FirebaseOptions(contentsOfFile: path) {
                FirebaseApp.configure(options: options)
            }
        }
        return true
    }
}
#endif

@main
struct NetBirdApp: App {
    // Create ViewModel on background thread to avoid blocking app launch with Go runtime init
    @StateObject private var viewModelLoader = ViewModelLoader()
    @Environment(\.scenePhase) var scenePhase

    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    #endif

    init() {
        // Defer Firebase initialization to avoid blocking app startup
        // Firebase is used for analytics/crashlytics - not critical for initial UI display
        #if os(tvOS)
        DispatchQueue.global(qos: .utility).async {
            if let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
               let options = FirebaseOptions(contentsOfFile: path) {
                FirebaseApp.configure(options: options)
            }
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            if let viewModel = viewModelLoader.viewModel {
                MainView()
                    .environmentObject(viewModel)
                        #if os(iOS)
                    .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                        print("App is active!")
                        viewModel.checkExtensionState()
                        viewModel.checkLoginRequiredFlag()
                        viewModel.startPollingDetails()
                    }
                    .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                        print("App is inactive!")
                        viewModel.stopPollingDetails()
                    }
                    #endif
                    #if os(tvOS)
                    // tvOS uses scenePhase changes
                    .onChange(of: scenePhase) { _, newPhase in
                        switch newPhase {
                        case .active:
                            print("App is active!")
                            viewModel.checkExtensionState()
                            viewModel.startPollingDetails()
                        case .inactive, .background:
                            print("App is inactive!")
                            viewModel.stopPollingDetails()
                        @unknown default:
                            break
                        }
                    }
                    #endif
            } else {
                // Show loading screen while ViewModel initializes
                Color.black
                    .ignoresSafeArea()
                    .overlay(
                        Image("netbird-logo-menu")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 300)
                    )
            }
        }
    }
}

/// Loads ViewModel asynchronously to avoid blocking app launch.
/// The Go runtime initialization (from NetBirdSDK) can take 10+ seconds on first launch.
@MainActor
class ViewModelLoader: ObservableObject {
    @Published var viewModel: ViewModel?

    init() {
        // Create ViewModel asynchronously on main thread
        // The ViewModel itself must be created on MainActor since it's an ObservableObject
        Task { @MainActor in
            let vm = ViewModel()
            self.viewModel = vm
        }
    }
}


