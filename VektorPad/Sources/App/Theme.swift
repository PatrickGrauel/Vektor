import SwiftUI
import UIKit

/// Numi-inspired palette, ported to iOS from the macOS app. Identical hex
/// values so the two apps share a brand identity; resolution uses
/// `UIColor(dynamicProvider:)` keyed on the trait collection's
/// `userInterfaceStyle` instead of AppKit's `NSAppearance.bestMatch`.
///
/// `VektorTheme.UI.*` are the source-of-truth dynamic `UIColor`s (used by
/// the UIKit-backed editor + gutter). `VektorTheme.*` are SwiftUI `Color`
/// wrappers over the same values.
enum VektorTheme {
    enum UI {
        /// Window / canvas background.
        static let background = dyn(dark: rgb(0x0E, 0x15, 0x21), light: rgb(0xF7, 0xF4, 0xEE))
        /// Slightly elevated surface for cards / chrome.
        static let surface    = dyn(dark: rgb(0x16, 0x1F, 0x30), light: rgb(0xEC, 0xE8, 0xDF))
        /// Accent — bright orange in dark, burnt sienna in light.
        static let accent     = dyn(dark: rgb(0xFF, 0x9F, 0x0F), light: rgb(0xC2, 0x61, 0x1F))
        /// Primary text.
        static let text       = dyn(dark: rgb(0xEE, 0xEE, 0xF2), light: rgb(0x1A, 0x1B, 0x1F))
        /// Secondary / muted text.
        static let muted      = dyn(dark: rgb(0x8F, 0x96, 0xA8), light: rgb(0x7C, 0x76, 0x6A))

        // Canonical tri-state status palette (always paired with an icon).
        static let statusGood    = dyn(dark: rgb(0x4F, 0xC6, 0x7B), light: rgb(0x1F, 0x8F, 0x46))
        static let statusCaution = dyn(dark: rgb(0xFF, 0xB3, 0x3F), light: rgb(0xB4, 0x60, 0x10))
        static let statusBad     = dyn(dark: rgb(0xFF, 0x6E, 0x6E), light: rgb(0xB4, 0x1C, 0x1C))

        /// Thin dividers / hairlines.
        static let divider     = dyn(dark: white(1.0, 0.08), light: white(0.0, 0.10))
        /// Background for typed surfaces (code blocks, search fields).
        static let codeSurface = dyn(dark: rgb(0x10, 0x19, 0x29), light: rgb(0xE2, 0xDD, 0xD0))

        // Secondary / tertiary chart lines.
        static let chartLine2 = dyn(dark: rgb(0x6F, 0xB7, 0xFF), light: rgb(0x1E, 0x6F, 0xD4))
        static let chartLine3 = dyn(dark: rgb(0xB9, 0x9C, 0xFF), light: rgb(0x6F, 0x42, 0xC1))

        private static func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> UIColor {
            UIColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
        }
        private static func white(_ w: CGFloat, _ a: CGFloat) -> UIColor {
            UIColor(white: w, alpha: a)
        }
        private static func dyn(dark: UIColor, light: UIColor) -> UIColor {
            UIColor { traits in traits.userInterfaceStyle == .dark ? dark : light }
        }
    }

    static var background: Color   { Color(UI.background) }
    static var surface: Color      { Color(UI.surface) }
    static var accent: Color       { Color(UI.accent) }
    static var text: Color         { Color(UI.text) }
    static var muted: Color        { Color(UI.muted) }
    static var statusGood: Color   { Color(UI.statusGood) }
    static var statusCaution: Color { Color(UI.statusCaution) }
    static var statusBad: Color    { Color(UI.statusBad) }
    static var divider: Color      { Color(UI.divider) }
    static var codeSurface: Color  { Color(UI.codeSurface) }
    static var chartLine2: Color   { Color(UI.chartLine2) }
    static var chartLine3: Color   { Color(UI.chartLine3) }
    static let overlayText = Color.white
}
