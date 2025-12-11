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
        // Configure Firebase with the plist file
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
    @StateObject var viewModel = ViewModel()
    @Environment(\.scenePhase) var scenePhase
    
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    #endif
    
    init() {
        // Configure Firebase on tvOS (no AppDelegate available)
        #if os(tvOS)
        if let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
           let options = FirebaseOptions(contentsOfFile: path) {
            FirebaseApp.configure(options: options)
        }
        #endif
    }
    
    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(viewModel)
                #if os(iOS)
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    print("App is active!")
                    viewModel.checkExtensionState()
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
        }
    }
}


