import AppKit
import SwiftUI

/// Owns the NSStatusItem. Click toggles the main window (Numi-style); right
/// click shows a small menu. The icon is a hand-drawn template glyph of the
/// equals-with-heading-bug mark so it adapts to light / dark menu bars.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    static let shared = MenuBarController()

    private var statusItem: NSStatusItem?
    /// The calculator surface. A non-activating `NSPanel` (not a SwiftUI
    /// WindowGroup window) so it can be summoned as the key window —
    /// receiving keystrokes for an immediate calculation — *without*
    /// activating the app or switching Spaces. That's what lets it appear
    /// over another app's full-screen Space every time, which the old
    /// `NSApp.activate`-based summon couldn't do reliably.
    private var panel: NSPanel?
    /// One-shot observer that drops the panel back to `.normal` when the
    /// user clicks away, so it doesn't float over everything forever
    /// (unless Always-on-Top is on). Re-armed on each summon.
    private var resignKeyObserver: NSObjectProtocol?
    /// Cached menu so we can re-attach it for right-click then detach.
    private lazy var contextMenu: NSMenu = makeMenu()

    /// Set by the panel's root view from a `@Environment(\.openSettings)`
    /// closure. Using SwiftUI's native action is much more reliable than
    /// the legacy `showSettingsWindow:` / `showPreferencesWindow:`
    /// selector dance — those depend on Apple's private responder
    /// chain hookup that has shifted between macOS releases.
    var openSettingsAction: (() -> Void)?

    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = Self.makeIcon()
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Vektor — click to toggle window, right-click for menu"
        }
        self.statusItem = item
    }

    func uninstall() {
        if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
        statusItem = nil
    }

    // MARK: - Click handling

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { toggleMainWindow(); return }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.type == .rightMouseUp || modifiers.contains(.control) {
            showMenu(for: sender)
        } else {
            toggleMainWindow()
        }
    }

    private func showMenu(for button: NSStatusBarButton) {
        // Present through the status item's *native* menu mechanism so the
        // menu drops flush from the menu bar and highlights the icon —
        // instead of the detached, free-floating look `menu.popUp(…)` gives.
        // We can't leave the menu permanently assigned (that would make a
        // plain left-click open the menu too, killing the window toggle),
        // so we attach it just for this interaction and detach again in
        // `menuDidClose`. Rebuilt each time so the "Menu Bar Only Mode"
        // checkmark stays accurate.
        guard let statusItem else { return }
        let menu = makeMenu()
        menu.delegate = self
        statusItem.menu = menu
        button.performClick(nil)
    }

    // MARK: - NSMenuDelegate

    func menuDidClose(_ menu: NSMenu) {
        // Detach so the next left-click routes to `handleClick` (toggle)
        // again rather than re-opening the menu. Deferred a runloop tick:
        // clearing inside the close notification can re-enter the click
        // machinery on some macOS versions.
        DispatchQueue.main.async { [weak self] in
            self?.statusItem?.menu = nil
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Vektor", action: #selector(menuOpen), keyEquivalent: "o").target = self
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Preferences…", action: #selector(menuPreferences), keyEquivalent: ",").target = self
        let menuBarOnlyItem = NSMenuItem(
            title: "Menu Bar Only Mode",
            action: #selector(menuToggleMenuBarOnly),
            keyEquivalent: ""
        )
        menuBarOnlyItem.target = self
        menuBarOnlyItem.state = isMenuBarOnly() ? .on : .off
        menu.addItem(menuBarOnlyItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit Vektor", action: #selector(menuQuit), keyEquivalent: "q").target = self
        return menu
    }

    // MARK: - Window toggle

    /// Configure the window to (a) appear on the current Space — even if
    /// that Space is another app in fullscreen — and (b) be reachable from
    /// any Space without yanking the user between Spaces. `.canJoinAllSpaces`
    /// and `.moveToActiveSpace` are mutually exclusive per Apple's docs, so
    /// remove the latter before inserting the former.
    static func prepareForCrossSpaceSummon(_ window: NSWindow) {
        window.collectionBehavior.remove(.moveToActiveSpace)
        window.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])
    }

    /// Lazily build the panel that hosts the calculator. Created once and
    /// reused — `orderOut` hides it, `showPanel` brings it back, and its
    /// SwiftUI state (open document, current pane) survives in between.
    private func makePanelIfNeeded() {
        guard panel == nil else { return }

        let hosting = NSHostingController(rootView: PanelRootView())
        let panel = QuickPanel(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable,
                        .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        // NO `panel.title` — the wordmark is drawn in-content (ContentView's
        // pane-switcher label). `titleVisibility = .hidden` alone is not
        // reliably honored for a .fullSizeContentView NSPanel: macOS can
        // still paint the grey system title over the content, doubling the
        // "Vektor" next to the traffic lights. An empty title removes the
        // glyph at the source; .hidden stays as belt-and-suspenders.
        panel.title = ""
        // Keep the window identifiable for VoiceOver / accessibility even
        // though no visual title is drawn.
        panel.setAccessibilityLabel("Vektor")
        // Reproduce the old WindowGroup's `.hiddenTitleBar`: transparent
        // title bar, content drawn full height, traffic lights overlaying
        // the top-left (ContentView's chrome pads 78pt to clear them).
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        // An NSPanel hides itself when the app deactivates *by default* —
        // fatal for a non-activating panel whose app is never "active."
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        Self.prepareForCrossSpaceSummon(panel)
        panel.contentMinSize = NSSize(width: 760, height: 520)

        // A floating / accessory-mode panel can't meaningfully miniaturize
        // to the Dock (which in Menu-Bar-Only mode isn't even there), so the
        // yellow button would just no-op. Retarget it to hide the panel —
        // the same "remove the interface" outcome as the menu-bar toggle.
        if let minimize = panel.standardWindowButton(.miniaturizeButton) {
            minimize.target = self
            minimize.action = #selector(hidePanel)
        }

        // Restore the last frame; first launch centers a default size.
        if !panel.setFrameUsingName("VektorMainPanel") {
            panel.setContentSize(NSSize(width: 860, height: 560))
            panel.center()
        }
        panel.setFrameAutosaveName("VektorMainPanel")

        self.panel = panel
    }

    /// Create (if needed) and summon the panel. Deliberately *no*
    /// `NSApp.activate(…)`: a `.nonactivatingPanel` becomes the key window
    /// — and so receives typing — on `makeKeyAndOrderFront` *without*
    /// activating the app, and it was that activation (on a regular
    /// window) that used to slide the user off another app's full-screen
    /// Space. `orderFrontRegardless` brings it forward even though the app
    /// stays in the background; the cross-space collection flags + floating
    /// level let it land on — and sit above — the current full-screen Space.
    func showPanel() {
        makePanelIfNeeded()
        guard let panel else { return }
        if panel.isMiniaturized { panel.deminiaturize(nil) }
        elevateForFullscreenOverlay(panel)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    /// Elevate to `.floating` so the panel overlays a full-screen app's
    /// window — the cross-space flags let it *join* the Space, but only a
    /// raised level puts it *above* the full-screen window. On the next
    /// `didResignKey` (user clicked back to the other app or another
    /// window) drop to `.normal` unless Always-on-Top is on, so the panel
    /// recedes instead of floating over everything forever. Re-armed on
    /// each summon.
    private func elevateForFullscreenOverlay(_ window: NSWindow) {
        window.level = .floating
        if let prev = resignKeyObserver {
            NotificationCenter.default.removeObserver(prev)
            resignKeyObserver = nil
        }
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            // Re-read the setting each fire — the user may have toggled it
            // since this observer was armed.
            let alwaysOnTop = UserDefaults.standard.bool(forKey: "vektor.alwaysOnTop")
            if !alwaysOnTop { window?.level = .normal }
            if let observer = self?.resignKeyObserver {
                NotificationCenter.default.removeObserver(observer)
                self?.resignKeyObserver = nil
            }
        }
    }

    /// `isVisible` is true for miniaturized and occluded windows, so
    /// combine the signals that actually correspond to "user can see it."
    private func mainWindowIsShowing() -> Bool {
        guard let panel, panel.isVisible, !panel.isMiniaturized else {
            return false
        }
        return panel.occlusionState.contains(.visible)
    }

    private func toggleMainWindow() {
        if mainWindowIsShowing() {
            // `orderOut` hides the panel from every Space; the next
            // `showPanel` re-summons it onto whatever Space the user is on.
            panel?.orderOut(nil)
        } else {
            showPanel()
        }
    }

    /// Hide the panel — wired to the yellow minimize button (see
    /// `makePanelIfNeeded`), since a floating panel can't miniaturize to a
    /// Dock that, in Menu-Bar-Only mode, isn't there.
    @objc private func hidePanel() {
        panel?.orderOut(nil)
    }

    // MARK: - Menu actions

    @objc private func menuOpen() {
        showPanel()
    }

    @objc private func menuPreferences() {
        NSApp.activate(ignoringOtherApps: true)
        // Prefer the SwiftUI-native action that the panel's SettingsBridge
        // wired up. It Just Works across macOS releases. Fall back to the
        // historical selectors only if the bridge hasn't installed yet
        // (Preferences clicked before the panel ever appeared) — and in
        // that case retry after the next runloop spin so the openSettings
        // callback has a chance to register.
        if let openSettings = openSettingsAction {
            openSettings()
            return
        }
        if NSApp.responds(to: Selector(("showSettingsWindow:"))) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else if NSApp.responds(to: Selector(("showPreferencesWindow:"))) {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        } else {
            // Final fallback: retry once after the runloop has had a
            // chance to wire up the SwiftUI bridge.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.openSettingsAction?()
            }
        }
    }

    @objc private func menuQuit() {
        NSApp.terminate(nil)
    }

    @objc private func menuToggleMenuBarOnly() {
        let new = !isMenuBarOnly()
        UserDefaults.standard.set(new, forKey: "vektor.menuBarOnly")
        applyActivationPolicy()
        contextMenu = makeMenu()  // refresh checkmark
    }

    // MARK: - Menu-bar-only mode (LSUIElement at runtime)

    func applyActivationPolicy() {
        if isMenuBarOnly() {
            NSApp.setActivationPolicy(.accessory)
            // macOS limitation: setting `.accessory` from `.regular` at
            // runtime SETS the policy correctly but the Dock icon often
            // persists visually until the next user-driven activation
            // edge. `deactivate()` nudges AppKit to refresh the Dock
            // state immediately in most cases. The fully-reliable path
            // is a process relaunch (see `relaunch()`).
            DispatchQueue.main.async {
                NSApp.deactivate()
            }
        } else {
            NSApp.setActivationPolicy(.regular)
            // .accessory → .regular is the supported direction and works
            // immediately; activate so the window comes to the front
            // visually too.
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func isMenuBarOnly() -> Bool {
        UserDefaults.standard.bool(forKey: "vektor.menuBarOnly")
    }

    /// Relaunch Vektor cleanly. The only fully reliable way to drop the
    /// Dock icon when transitioning to Menu-Bar-Only mode mid-session
    /// (and the only way to be sure the menu/activation state is in a
    /// clean state after any settings change). Sandbox-safe: opens the
    /// app bundle via NSWorkspace, then terminates the current process.
    func relaunch() {
        let url = Bundle.main.bundleURL
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        Task {
            // Best-effort: even if `openApplication` returns an error,
            // still terminate so the user doesn't see a broken half-state.
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: cfg)
            await MainActor.run { NSApp.terminate(nil) }
        }
    }

    // MARK: - Icon

    /// Draws the equals + heading bug shape as a 18×18 template image.
    /// macOS will tint it appropriately for the menu bar style.
    private static func makeIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()

            // Two rounded equals bars
            let barHeight: CGFloat = 3
            let barCornerRadius: CGFloat = 1.5
            let barWidth: CGFloat = 12
            let barX = (rect.width - barWidth) / 2

            let topBarY: CGFloat = 9
            let bottomBarY: CGFloat = 4
            NSBezierPath(roundedRect: NSRect(x: barX, y: topBarY,
                                              width: barWidth, height: barHeight),
                         xRadius: barCornerRadius, yRadius: barCornerRadius).fill()
            NSBezierPath(roundedRect: NSRect(x: barX, y: bottomBarY,
                                              width: barWidth, height: barHeight),
                         xRadius: barCornerRadius, yRadius: barCornerRadius).fill()

            // Tiny heading-bug triangle above the top bar
            let bug = NSBezierPath()
            let cx = rect.width / 2
            let bugTopY = topBarY + barHeight + 3
            let bugBottomY = topBarY + barHeight + 0.6
            bug.move(to: NSPoint(x: cx - 2, y: bugTopY))
            bug.line(to: NSPoint(x: cx + 2, y: bugTopY))
            bug.line(to: NSPoint(x: cx,     y: bugBottomY))
            bug.close()
            bug.fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// Non-activating panel that can still become the key window, so the
/// calculator receives keystrokes the instant it's summoned — even while
/// another app owns the active / full-screen Space. A borderless or
/// non-activating panel returns `false` from `canBecomeKey` by default,
/// which would leave the editor unable to take focus; override it.
final class QuickPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Root of the panel's SwiftUI tree: the calculator, the shared model, and
/// a tiny bridge that hands SwiftUI's native `openSettings` action to
/// MenuBarController (more reliable than the `showSettingsWindow:` selector
/// in accessory mode). `.frame(minWidth:minHeight:)` mirrors what the old
/// WindowGroup wrapper applied.
private struct PanelRootView: View {
    @StateObject private var ent = EntitlementManager.shared

    var body: some View {
        ContentView()
            .environmentObject(AppModel.shared)
            .environmentObject(ent)
            .frame(minWidth: 760, minHeight: 520)
            .background(SettingsBridge())
            // No trial chrome on the calculator surface — during the trial the
            // app looks completely normal. "Unlock" lives in Settings; the
            // paywall appears only once the 7 days have actually run out.
            .overlay {
                if !ent.isUnlocked {
                    PaywallView()
                        .environmentObject(ent)
                }
            }
    }
}

private struct SettingsBridge: View {
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                MenuBarController.shared.openSettingsAction = { openSettings() }
            }
    }
}
