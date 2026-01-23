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

@main
struct NetBirdApp: App {
    @StateObject private var viewModelLoader = ViewModelLoader()
    @Environment(\.scenePhase) var scenePhase

    var body: some Scene {
        WindowGroup {
            if let viewModel = viewModelLoader.viewModel {
                MainView()
                    .environmentObject(viewModel)
                    .onAppear {
                        // Initialize Firebase after UI is displayed to avoid blocking app launch
                        DispatchQueue.main.async {
                            if let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
                               let options = FirebaseOptions(contentsOfFile: path) {
                                FirebaseApp.configure(options: options)
                            }
                        }

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
