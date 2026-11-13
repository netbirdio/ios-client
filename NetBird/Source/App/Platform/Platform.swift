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

    /// `width` clamped to the content column. On iPhone this is the raw width (no
    /// iPhone is wider than the cap and the app is portrait-locked); on iPad it is a
    /// constant, which is why callers cannot hold a stale reading across a rotation.
    static var contentWidth: CGFloat { min(width, Layout.maxContentWidth) }

    /// `height` clamped the same way, for the proportional vertical paddings.
    static var contentHeight: CGFloat { min(height, Layout.maxContentHeight) }

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

    /// Widest a phone-shaped content column is allowed to get.
    ///
    /// Scoped to decorative content only (see `View.contentColumn()`) — the
    /// empty-state icon and message that have no natural HIG size of their
    /// own to defer to. Functional content (controls, informational text)
    /// uses `View.readableWidth()` instead, which asks the system for its
    /// actual readable width rather than guessing one.
    ///
    /// Below 744pt — the shortest edge any current iPad shows in *either*
    /// orientation (iPad mini's landscape height, same as its portrait width) —
    /// so the resulting width does not change when the device rotates, on any
    /// iPad in the lineup. Above 430pt, the widest current iPhone, so the column
    /// is never narrower than a phone would already show. tvOS returns the full
    /// width, making every `contentColumn()`/`contentWidth` caller a provable
    /// no-op there.
    static var maxContentWidth: CGFloat {
        DeviceType.isTV ? Screen.width : 500
    }

    /// Companion cap for the proportional vertical paddings.
    ///
    /// Height can't reuse `maxContentWidth`'s "one constant for every non-TV
    /// device" trick: the tallest current iPhone (932pt, 15/16 Pro Max) is
    /// *taller* than the shortest edge any iPad shows (744pt, iPad mini's
    /// landscape height — the same 744 as its portrait width). So "large enough
    /// to be a no-op on every iPhone" and "small enough to stay constant across
    /// iPad rotation" are contradictory requirements for a single flat number —
    /// unlike width, where the widest iPhone (430pt) sits safely below that same
    /// 744pt floor. Branch by idiom instead: iPhone gets its own height back
    /// (an exact no-op, not an approximation), iPad gets a value below 744pt.
    static var maxContentHeight: CGFloat {
        if DeviceType.isTV { return Screen.height }
        if DeviceType.isPad { return 500 }
        return Screen.height
    }

    /// Apple's documented practical range for a custom popover-style overlay:
    /// "works well when the content size will fit within the typical popover
    /// size (300-400 points wide)... once you start to exceed 600 points wide
    /// you run the risk the popover will not fit." A ceiling, not a fixed
    /// width — HIG: "avoid making a popover too big... make it only big
    /// enough to display its contents and point to the place it came from."
    static var popoverMaxWidth: CGFloat { 320 }
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

    /// Caps the view to a phone-shaped column and centres it — iPad only.
    ///
    /// For decorative content that has no natural HIG size of its own to
    /// defer to (see `Layout.maxContentWidth`); functional content should
    /// use `readableWidth()` instead. The branch is on `DeviceType.isPad`, a
    /// value fixed for the life of the process, so this never churns view
    /// identity; on iPhone the `.frame` simply isn't in the tree, which is
    /// what makes "portrait iPhone is unaffected" true by construction
    /// rather than by argument.
    @ViewBuilder
    func contentColumn() -> some View {
        if DeviceType.isPad {
            self.frame(maxWidth: Layout.maxContentWidth)
        } else {
            self
        }
    }

    /// Constrains this view to Apple's system-computed readable content
    /// width (`UIView.readableContentGuide`), centred in the available
    /// space — the same guide `UITableView`/`UICollectionView` use to keep
    /// list and form content from stretching edge-to-edge on a large iPad,
    /// rather than a hand-picked constant. Adapts live to Dynamic Type,
    /// orientation and size class, the same way those system views do.
    ///
    /// Until the underlying probe's first layout pass reports a value, the
    /// view is unconstrained (its natural, full available width), so
    /// content never collapses to zero-width on first appearance.
    func readableWidth() -> some View {
        modifier(ReadableWidthModifier())
    }
}

/// Bridges UIKit's `readableContentGuide` into SwiftUI — see
/// `View.readableWidth()`.
private struct ReadableWidthModifier: ViewModifier {
    @State private var width: CGFloat?

    func body(content: Content) -> some View {
        ZStack {
            // A sibling of `content`, not a modifier chained onto it after
            // its own frame is applied: the probe must be proposed the
            // *unconstrained* available width to measure against, or the
            // guide would compute from an already-narrowed container and
            // feed back on itself.
            ReadableWidthProbe(width: $width)

            content
                .frame(maxWidth: width)
        }
    }
}

private struct ReadableWidthProbe: UIViewRepresentable {
    @Binding var width: CGFloat?

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.onLayout = { [weak view] in
            guard let measured = view?.readableContentGuide.layoutFrame.width,
                  measured > 0 else { return }
            if width != measured { width = measured }
        }
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {}

    final class ProbeView: UIView {
        var onLayout: (() -> Void)?

        override func layoutSubviews() {
            super.layoutSubviews()
            onLayout?()
        }
    }
}


