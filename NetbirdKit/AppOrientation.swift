//
//  AppOrientation.swift
//  NetbirdKit
//
//  The app is portrait-only, but the SSH terminal earns landscape: it roughly
//  doubles the column count, which is what long command lines and full-screen
//  programs need. The Android client makes the same exception for the same
//  reason, and for the same one screen.
//
//  The Info.plist has to advertise every orientation the app may ever adopt, so
//  the actual restriction lives here and is applied through the app delegate's
//  supportedInterfaceOrientationsFor callback.
//

import UIKit

#if os(iOS)

enum AppOrientation {

    /// What the app delegate reports. Portrait everywhere except the terminal.
    private(set) static var mask: UIInterfaceOrientationMask = .portrait

    /// Opens the app up to landscape, or closes it back down. Closing it also
    /// rotates the device back, since a window left in landscape would show the
    /// next screen in a layout that was never designed for it.
    static func allowLandscape(_ allowed: Bool) {
        let next: UIInterfaceOrientationMask = allowed ? [.portrait, .landscape] : .portrait
        guard next != mask else { return }
        mask = next
        apply(next)
    }

    private static func apply(_ mask: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
        else { return }

        if #available(iOS 16.0, *) {
            scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
                AppLogger.shared.log("AppOrientation: geometry update refused: \(error.localizedDescription)")
            }
        } else {
            // Pre-16 has no geometry request; assigning the device orientation
            // is what nudges the window, and attemptRotationToDeviceOrientation
            // makes UIKit re-ask the delegate for the new mask.
            let orientation: UIInterfaceOrientation = mask.contains(.landscape) ? .landscapeLeft : .portrait
            UIDevice.current.setValue(orientation.rawValue, forKey: "orientation")
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }
}

#endif
