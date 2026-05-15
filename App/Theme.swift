import SwiftUI
import AppKit

/// Numi-inspired palette. Dark variant pulled from the Tally icon (navy);
/// light variant is a warm off-white with deep ink text. Each token is an
/// `NSColor`-backed dynamic colour that re-resolves when the system or the
/// user's appearance preference changes.
enum TallyTheme {
    /// Window / canvas background.
    static let background = dyn(
        dark:  NSColor(red: 0x0E/255, green: 0x15/255, blue: 0x21/255, alpha: 1),
        light: NSColor(red: 0xF7/255, green: 0xF4/255, blue: 0xEE/255, alpha: 1)
    )

    /// Slightly elevated surface for popovers / chrome.
    static let surface = dyn(
        dark:  NSColor(red: 0x16/255, green: 0x1F/255, blue: 0x30/255, alpha: 1),
        light: NSColor(red: 0xEC/255, green: 0xE8/255, blue: 0xDF/255, alpha: 1)
    )

    /// Accent (timezone results, active selection). Same in both modes.
    static let accent = Color(red: 0xFF/255, green: 0x9F/255, blue: 0x0F/255)

    /// Secondary chart line — used when a drill-down chart needs to
    /// plot a second metric alongside the accent-colored primary
    /// (e.g. R&D% next to SG&A% on Cost Discipline). Cool blue chosen
    /// to read as "different category" against the warm accent.
    static let chartLine2 = dyn(
        dark:  NSColor(red: 0x6F/255, green: 0xB7/255, blue: 0xFF/255, alpha: 1),
        light: NSColor(red: 0x1E/255, green: 0x6F/255, blue: 0xD4/255, alpha: 1)
    )

    /// Tertiary chart line — third metric on the same chart
    /// (e.g. Depreciation% on Cost Discipline). Muted purple so the
    /// three-way comparison stays legible without becoming a rainbow.
    static let chartLine3 = dyn(
        dark:  NSColor(red: 0xB9/255, green: 0x9C/255, blue: 0xFF/255, alpha: 1),
        light: NSColor(red: 0x6F/255, green: 0x42/255, blue: 0xC1/255, alpha: 1)
    )

    /// Primary text.
    static let text = dyn(
        dark:  NSColor(red: 0xEE/255, green: 0xEE/255, blue: 0xF2/255, alpha: 1),
        light: NSColor(red: 0x1A/255, green: 0x1B/255, blue: 0x1F/255, alpha: 1)
    )

    /// Secondary / muted text.
    static let muted = dyn(
        dark:  NSColor(red: 0x8F/255, green: 0x96/255, blue: 0xA8/255, alpha: 1),
        light: NSColor(red: 0x7C/255, green: 0x76/255, blue: 0x6A/255, alpha: 1)
    )

    // MARK: - Status palette
    //
    // One canonical tri-state used everywhere a result is judged. Same
    // hues across modes; mild contrast adjustments so the light-mode
    // variants don't shout. Always paired with an icon (`StatusBadge`)
    // so the signal is dual-channel and survives red-green colour
    // deficiency.
    static let statusGood = dyn(
        dark:  NSColor(red: 0x4F/255, green: 0xC6/255, blue: 0x7B/255, alpha: 1),
        light: NSColor(red: 0x1F/255, green: 0x8F/255, blue: 0x46/255, alpha: 1)
    )
    static let statusCaution = dyn(
        dark:  NSColor(red: 0xFF/255, green: 0xB3/255, blue: 0x3F/255, alpha: 1),
        light: NSColor(red: 0xB4/255, green: 0x60/255, blue: 0x10/255, alpha: 1)
    )
    static let statusBad = dyn(
        dark:  NSColor(red: 0xFF/255, green: 0x6E/255, blue: 0x6E/255, alpha: 1),
        light: NSColor(red: 0xB4/255, green: 0x1C/255, blue: 0x1C/255, alpha: 1)
    )

    /// Thin dividers / hairlines. The system `Divider()` colour is too
    /// loud against navy and too faint against cream.
    static let divider = dyn(
        dark:  NSColor(white: 1.0, alpha: 0.08),
        light: NSColor(white: 0.0, alpha: 0.10)
    )

    /// Background for inline code blocks, popover search fields, and any
    /// other "this is a typed thing" surface that needs more contrast
    /// than `surface` provides.
    static let codeSurface = dyn(
        dark:  NSColor(red: 0x10/255, green: 0x19/255, blue: 0x29/255, alpha: 1),
        light: NSColor(red: 0xE2/255, green: 0xDD/255, blue: 0xD0/255, alpha: 1)
    )

    /// White text dropped onto map / chart legends that sit over an
    /// always-dark capsule. Doesn't flip in light mode because the
    /// capsule under it doesn't either.
    static let overlayText = Color.white

    private static func dyn(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let best = appearance.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark])
            switch best {
            case .darkAqua, .vibrantDark: return dark
            default:                       return light
            }
        })
    }
}
