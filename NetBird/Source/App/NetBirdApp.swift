//
//  NetBirdiOSApp.swift
//  NetBirdiOS
//
//  Created by Pascal Fischer on 01.08.23.
//

import SwiftUI
import FirebaseCore
import FirebasePerformance

class AppDelegate: NSObject, UIApplicationDelegate {
  func application(_ application: UIApplication,
                   didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
      let options = FirebaseOptions(contentsOfFile: Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist")!)
      FirebaseApp.configure(options: options!)
    return true
  }
}


@main
struct NetBirdApp: App {
    @StateObject var viewModel = ViewModel()
    @Environment(\.scenePhase) var scenePhase
    
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    
    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(viewModel)
                .onChange(of: scenePhase) { newPhase in
                    switch newPhase {
                    case .background:
                        print("App moved to background")
                        viewModel.networkExtensionAdapter.setBackgroundMode(true)
                        viewModel.stopPollingDetails()
                    case .active:
                        print("App became active")
                        // Delay state updates to avoid blocking app launch
                        // These operations use semaphores that could block if pollingQueue is busy
                        // checkExtensionState() is delayed to prevent blocking if extension is not configured
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            viewModel.networkExtensionAdapter.setBackgroundMode(false)
                            viewModel.networkExtensionAdapter.setInactiveMode(false)
                        }
                        // Check extension state asynchronously without blocking app launch
                        // This ensures app can start even if extension is not configured or not running
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            viewModel.checkExtensionState()
                            // Only start polling if extension is connected to avoid unnecessary fetchData calls
                            // startTimer() invalidates existing timer and calls fetchData(), which is wasteful if not connected
                            if viewModel.extensionState == .connected {
                                viewModel.startPollingDetails()
                            }
                        }
                    case .inactive:
                        print("App became inactive")
                        // Use slower polling when app becomes inactive (e.g., app switcher, control center)
                        // This maintains VPN connection monitoring while saving battery during brief inactive periods
                        viewModel.networkExtensionAdapter.setInactiveMode(true)
                    @unknown default:
                        break
                    }
                }
        }
    }
}
