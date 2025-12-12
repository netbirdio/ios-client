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
                        viewModel.networkExtensionAdapter.setBackgroundMode(false)
                        viewModel.checkExtensionState()
                        viewModel.startPollingDetails()
                    case .inactive:
                        break
                    @unknown default:
                        break
                    }
                }
        }
    }
}
