//
//  TVColors.swift
//  NetBird
//
//  Shared styling definitions for tvOS views.
//  Provides colors and layout constants for the 10-foot TV experience.
//

import SwiftUI

#if os(tvOS)
import UIKit

// MARK: - TVColors

/// Centralized color definitions for all tvOS views.
/// Uses named colors from asset catalog with sensible fallbacks.
struct TVColors {

    // MARK: - Text Colors

    static var textPrimary: Color {
        colorOrFallback("TextPrimary", fallback: .primary)
    }

    static var textSecondary: Color {
        colorOrFallback("TextSecondary", fallback: .secondary)
    }

    static var textAlert: Color {
        colorOrFallback("TextAlert", fallback: .white)
    }

    // MARK: - Background Colors

    static var bgMenu: Color {
        colorOrFallback("BgMenu", fallback: Color(white: 0.1))
    }

    static var bgPrimary: Color {
        colorOrFallback("BgPrimary", fallback: Color(white: 0.15))
    }

    static var bgSecondary: Color {
        colorOrFallback("BgSecondary", fallback: Color(white: 0.08))
    }

    static var bgSideDrawer: Color {
        colorOrFallback("BgSideDrawer", fallback: Color(white: 0.2))
    }

    // MARK: - Gradient Colors

    /// Top-leading color for the full-screen gradient background.
    static var gradientTop: Color {
        Color(red: 0.10, green: 0.10, blue: 0.20)
    }

    /// Bottom-trailing color for the full-screen gradient background.
    static var gradientBottom: Color {
        Color(red: 0.03, green: 0.03, blue: 0.06)
    }

    // MARK: - Helper

    private static func colorOrFallback(_ name: String, fallback: Color) -> Color {
        UIColor(named: name) != nil ? Color(name) : fallback
    }
}

// MARK: - TVLayout

/// Centralized layout constants for tvOS.
/// All dimensions optimized for the "10-foot experience" (viewing from couch distance).
struct TVLayout {

    // MARK: - Content Padding

    /// Standard content padding from screen edges
    static let contentPadding: CGFloat = 80

    /// Padding inside cards/sections
    static let cardPadding: CGFloat = 30

    /// Padding inside detail panels
    static let detailPadding: CGFloat = 40

    /// Padding for dialog/alert content
    static let dialogPadding: CGFloat = 60

    // MARK: - Spacing

    /// Large spacing between major sections
    static let sectionSpacing: CGFloat = 40

    /// Medium spacing between related elements
    static let elementSpacing: CGFloat = 20

    /// Small spacing within grouped items
    static let itemSpacing: CGFloat = 15

    /// Horizontal spacing between columns
    static let columnSpacing: CGFloat = 100

    /// Spacing between filter buttons
    static let filterSpacing: CGFloat = 35

    // MARK: - Sizes

    /// Logo width on main screens (brand anchor, top-left)
    static let logoWidth: CGFloat = 150

    /// Logo width on secondary screens (dialogs, info panels)
    static let logoWidthSmall: CGFloat = 200

    /// Side panel/detail view width
    static let sidePanelWidth: CGFloat = 500

    /// Info panel width (server view, etc.)
    static let infoPanelWidth: CGFloat = 400

    /// QR code size for auth view
    static let qrCodeSize: CGFloat = 280

    // MARK: - Corner Radius

    /// Large corner radius for major containers
    static let cornerRadiusLarge: CGFloat = 24

    /// Medium corner radius for cards
    static let cornerRadiusMedium: CGFloat = 20

    /// Small corner radius for buttons/inputs
    static let cornerRadiusSmall: CGFloat = 12

    // MARK: - Font Sizes

    /// Page title (e.g., "Settings", "Peers")
    static let fontTitle: CGFloat = 48

    /// Section header
    static let fontHeader: CGFloat = 36

    /// Card title / primary text
    static let fontBody: CGFloat = 32

    /// Secondary/subtitle text
    static let fontSubtitle: CGFloat = 28

    /// Small/caption text
    static let fontCaption: CGFloat = 24

    /// Device code display (auth view)
    static let fontDeviceCode: CGFloat = 64

    // MARK: - Button Dimensions

    /// Horizontal padding for primary buttons
    static let buttonPaddingH: CGFloat = 50

    /// Vertical padding for primary buttons
    static let buttonPaddingV: CGFloat = 18

    /// Button font size
    static let buttonFontSize: CGFloat = 30

    // MARK: - Focus Effects

    /// Scale factor when element is focused
    static let focusScale: CGFloat = 1.02

    /// Scale factor for large focused buttons
    static let focusScaleLarge: CGFloat = 1.1

    /// Border width when focused
    static let focusBorderWidth: CGFloat = 4
}

#endif