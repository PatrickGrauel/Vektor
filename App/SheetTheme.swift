import SwiftUI

/// Applies Tally's navy / cream theme to a sheet's contents. macOS sheets
/// otherwise default to system-window-background, which shows up as a flat
/// light-grey in dark mode — jarring next to the themed main window.
extension View {
    /// Wraps the view in Tally's themed surface. Use on the **root** view of
    /// every sheet, popover, or auxiliary window.
    func themedSheet(_ scheme: ColorScheme? = nil) -> some View {
        modifier(ThemedSheetModifier(scheme: scheme))
    }
}

private struct ThemedSheetModifier: ViewModifier {
    let scheme: ColorScheme?
    @AppStorage("tally.appearance") private var appearance: String = "system"

    func body(content: Content) -> some View {
        content
            .background(TallyTheme.background.ignoresSafeArea())
            .preferredColorScheme(resolved)
    }

    private var resolved: ColorScheme? {
        if let scheme { return scheme }
        switch appearance {
        case "light": return .light
        case "dark":  return .dark
        default:      return nil
        }
    }
}
