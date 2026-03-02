//
//  Platform.swift
//  NetBird
//
//  Platform abstraction layer for iOS/tvOS compatibility.
//  This file provides unified APIs that work across both platforms,
//  hiding the differences behind simple, consistent interfaces.
//

import SwiftUI
import Combine

// Screen Size Abstraction
/// Replaces direct UIScreen.main.bounds usage which isn't ideal for tvOS.
struct Screen {
    
    /// Screen width in points
    static var width: CGFloat {
        #if os(tvOS)
        // Apple TV is always 1920x1080 (or 3840x2160 for 4K, but points are same)
        return 1920
        #else
        return UIScreen.main.bounds.width
        #endif
    }
    
    static var height: CGFloat {
        #if os(tvOS)
        return 1080
        #else
        return UIScreen.main.bounds.height
        #endif
    }
    
    /// Full screen bounds as CGRect
    static var bounds: CGRect {
        CGRect(x: 0, y: 0, width: width, height: height)
    }
    
    /// Safe way to calculate proportional sizes
    /// - Parameters:
    ///   - widthRatio: Fraction of screen width (0.0 to 1.0)
    ///   - heightRatio: Fraction of screen height (0.0 to 1.0)
    /// - Returns: CGSize proportional to screen
    static func size(widthRatio: CGFloat = 1.0, heightRatio: CGFloat = 1.0) -> CGSize {
        CGSize(width: width * widthRatio, height: height * heightRatio)
    }
}

// Device Type Detection
/// Identifies what type of Apple device we're running on.
/// Useful for conditional UI layouts and feature availability.
struct DeviceType {
    static var isTV: Bool {
        #if os(tvOS)
        return true
        #else
        return false
        #endif
    }
    
    static var isPad: Bool {
        #if os(tvOS)
        return false
        #else
        return UIDevice.current.userInterfaceIdiom == .pad
        #endif
    }
    
    static var isPhone: Bool {
        #if os(tvOS)
        return false
        #else
        return UIDevice.current.userInterfaceIdiom == .phone
        #endif
    }
    
    /// Returns appropriate scale factor for the current device type.
    /// Useful for sizing UI elements proportionally.
    static var scaleFactor: CGFloat {
        if isTV {
            return 2.0  // TV needs larger UI elements
        } else if isPad {
            return 1.3
        } else {
            return 1.0
        }
    }
}

struct PlatformCapabilities {
    static var supportsVPN: Bool {
        #if os(tvOS)
        if #available(tvOS 17.0, *) {
            return true
        }
        return false
        #else
        return true  // iOS has always supported VPN
        #endif
    }
    
    static var supportsSafariView: Bool {
        #if os(tvOS)
        return false
        #else
        return true
        #endif
    }
    
    static var hasTouchScreen: Bool {
        #if os(tvOS)
        return false
        #else
        return true
        #endif
    }
    
    static var supportsClipboard: Bool {
        #if os(tvOS)
        return false
        #else
        return true
        #endif
    }
    
    static var supportsKeyboard: Bool {
        true
    }
}

struct Layout {
    
    /// Standard padding for content edges
    static var contentPadding: CGFloat {
        DeviceType.isTV ? 80 : 16
    }
    
    /// Padding between UI elements
    static var elementSpacing: CGFloat {
        DeviceType.isTV ? 40 : 12
    }
    
    /// Standard corner radius for cards and buttons
    static var cornerRadius: CGFloat {
        DeviceType.isTV ? 20 : 10
    }
    
    /// Minimum touch/focus target size (Apple HIG compliance)
    static var minTapTarget: CGFloat {
        DeviceType.isTV ? 66 : 44  // Apple's minimum for accessibility
    }
    
    /// Font size multiplier for the platform
    static var fontScale: CGFloat {
        DeviceType.isTV ? 1.5 : 1.0
    }
}

// Scaled Font Helper
/// Creates fonts that scale appropriately for each platform.
extension Font {
    /// Creates a system font scaled for the current platform
    static func scaledSystem(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size * Layout.fontScale, weight: weight)
    }
}

// View Modifiers for Platform Adaptation
extension View {
    /// Applies platform-appropriate padding
    func platformPadding(_ edges: Edge.Set = .all) -> some View {
        self.padding(edges, Layout.contentPadding)
    }

    /// Makes the view focusable on tvOS (no-op on iOS)
    @ViewBuilder
    func tvFocusable() -> some View {
        #if os(tvOS)
        self.focusable()
        #else
        self
        #endif
    }
}


