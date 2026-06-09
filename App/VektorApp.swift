import SwiftUI
import AppKit

@main
struct VektorApp: App {
    // App lifecycle (status item, activation policy, panel, Dock-icon
    // reopen) lives in the AppDelegate. The calculator UI is no longer a
    // SwiftUI WindowGroup — it's a non-activating NSPanel owned by
    // MenuBarController so it can be summoned over full-screen Spaces.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // One-shot migration of secrets out of UserDefaults into the
        // Keychain. Each call is a no-op once the corresponding key
        // already lives in the Keychain. Runs synchronously on app
        // launch so the rest of the app reads from the new home from
        // the very first frame.
        KeychainStorage.migrateFromUserDefaults("vektor.stocks.fmpApiKey")
        KeychainStorage.migrateFromUserDefaults("vektor.fx.openExchangeRatesKey")

        // First-launch default for precision: 2 decimal places, matching
        // common currency / pilot-friendly display. The engine's own
        // fallback stays at 14 so tests (which run against a clean
        // UserDefaults) keep their strip-trailing-zeros behavior — this
        // migration writes a value once on first launch so end-users see
        // `4.00` instead of `4` from day one. No-op for users who already
        // have an explicit value stored (whether they set it themselves
        // or carried it over from earlier launches).
        if UserDefaults.standard.object(forKey: "vektor.precision") == nil {
            UserDefaults.standard.set(2, forKey: "vektor.precision")
        }
    }

    var body: some Scene {
        // The only SwiftUI scene is Settings, opened from the status-bar
        // menu's "Preferences…" via the `openSettings` action (wired into
        // MenuBarController from the panel's root view).
        Settings {
            SettingsView()
                .environmentObject(AppModel.shared)
        }
    }
}

/// Owns app lifecycle. Lives here rather than a `MenuBarBoot` @StateObject
/// so we can answer `applicationShouldHandleReopen` — the Dock-icon click
/// that should re-summon the panel for users who keep the Dock icon (i.e.
/// not Menu-Bar-Only mode).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MenuBarController.shared.install()
        MenuBarController.shared.applyActivationPolicy()
        // Show the panel at launch, matching the old WindowGroup which
        // materialised the window at launch (this is also what kicks
        // ContentView's `.task { bootstrapLiveData() }`).
        MenuBarController.shared.showPanel()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        // Dock-icon click (regular mode) or `open -a Vektor` while running.
        MenuBarController.shared.showPanel()
        return true
    }
}
