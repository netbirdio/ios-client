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
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) {_ in
                    print("App is active!")
                    viewModel.checkExtensionState()
                    viewModel.startPollingDetails()
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) {_ in
                    print("App is inactive!")
                    viewModel.stopPollingDetails()
                }
        }
    }
}
