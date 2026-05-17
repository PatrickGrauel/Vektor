import SwiftUI
import AppKit

@main
struct TallyApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var menuBarBoot = MenuBarBoot()
    @Environment(\.openWindow) private var openWindow
    @AppStorage("tally.alwaysOnTop") private var alwaysOnTop: Bool = false

    init() {
        // One-shot migration of secrets out of UserDefaults into the
        // Keychain. Each call is a no-op once the corresponding key
        // already lives in the Keychain. Runs synchronously on app
        // launch so the rest of the app reads from the new home from
        // the very first frame.
        KeychainStorage.migrateFromUserDefaults("tally.stocks.fmpApiKey")
        KeychainStorage.migrateFromUserDefaults("tally.fx.openExchangeRatesKey")

        // First-launch default for precision: 2 decimal places, matching
        // common currency / pilot-friendly display. The engine's own
        // fallback stays at 14 so tests (which run against a clean
        // UserDefaults) keep their strip-trailing-zeros behavior — this
        // migration writes a value once on first launch so end-users see
        // `4.00` instead of `4` from day one. No-op for users who already
        // have an explicit value stored (whether they set it themselves
        // or carried it over from earlier launches).
        if UserDefaults.standard.object(forKey: "tally.precision") == nil {
            UserDefaults.standard.set(2, forKey: "tally.precision")
        }
    }

    var body: some Scene {
        WindowGroup("Vektor", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 520)
                .background(WindowLevelApplier(alwaysOnTop: alwaysOnTop))
                .background(CrossSpaceSummonApplier())
                .background(WindowOpenerBridge())
        }
        .windowResizability(.contentSize)
        // Hide the native title bar so the toolbar — which on Sonoma+
        // wraps each item in a capsule background — disappears.
        // Traffic lights still overlay the content's top-left corner;
        // ContentView's custom chrome bar leaves padding for them.
        .windowStyle(.hiddenTitleBar)

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}

/// Pins the hosting window to `.floating` when Always-on-Top is enabled.
/// Restricted to the actual content window — never touches the MenuBarExtra
/// status-item window (which would cause a redraw storm).
private struct WindowLevelApplier: NSViewRepresentable {
    let alwaysOnTop: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            let desired: NSWindow.Level = alwaysOnTop ? .floating : .normal
            if window.level != desired {
                window.level = desired
            }
        }
    }
}

/// Configures the hosting window to appear on the active Space and
/// pierce fullscreen apps. Applied via `.background` on the WindowGroup
/// root so every freshly-created window gets the flags from the start.
private struct CrossSpaceSummonApplier: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            MenuBarController.prepareForCrossSpaceSummon(window)
        }
    }
}

/// Hands SwiftUI's `openWindow` and `openSettings` actions to
/// MenuBarController so the NSObject world can (re)open the "main"
/// WindowGroup window and the Settings scene reliably across macOS
/// releases. The historical `showSettingsWindow:` / `showPreferencesWindow:`
/// selectors aren't always wired into the responder chain when the app
/// is running in `.accessory` mode, so going via SwiftUI's native
/// environment actions is much more robust.
private struct WindowOpenerBridge: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                MenuBarController.shared.openMainWindow = {
                    openWindow(id: "main")
                }
                MenuBarController.shared.openSettingsAction = {
                    openSettings()
                }
            }
    }
}

/// Drives the menu bar installation + activation policy at app startup.
@MainActor
final class MenuBarBoot: ObservableObject {
    init() {
        MenuBarController.shared.install()
        MenuBarController.shared.applyActivationPolicy()
    }
}
