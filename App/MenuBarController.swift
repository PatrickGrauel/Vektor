import AppKit
import SwiftUI

/// Owns the NSStatusItem. Click toggles the main window (Numi-style); right
/// click shows a small menu. The icon is a hand-drawn template glyph of the
/// equals-with-heading-bug mark so it adapts to light / dark menu bars.
@MainActor
final class MenuBarController: NSObject {
    static let shared = MenuBarController()

    private var statusItem: NSStatusItem?
    /// Cached menu so we can re-attach it for right-click then detach.
    private lazy var contextMenu: NSMenu = makeMenu()

    /// Set by WindowOpenerBridge once the WindowGroup scene has appeared.
    /// Calling this asks SwiftUI to (re)open the "main" window — needed
    /// because closing the window via the red X destroys the NSWindow
    /// and nothing in AppKit can resurrect a SwiftUI WindowGroup window.
    var openMainWindow: (() -> Void)?

    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = Self.makeIcon()
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Tally — click to toggle window, right-click for menu"
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
        // Rebuild every time so the "Menu Bar Only Mode" checkmark stays
        // accurate. Pop it up manually rather than attaching to statusItem
        // (which would also intercept left-clicks).
        let menu = makeMenu()
        let location = NSPoint(x: 0, y: button.bounds.height + 4)
        menu.popUp(positioning: nil, at: location, in: button)
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Tally", action: #selector(menuOpen), keyEquivalent: "o").target = self
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
        menu.addItem(withTitle: "Quit Tally", action: #selector(menuQuit), keyEquivalent: "q").target = self
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

    private func mainWindow() -> NSWindow? {
        // ContentView sets navigationTitle("") so window.title is empty —
        // we identify the WindowGroup("Tally", id: "main") window by its
        // SwiftUI-assigned identifier instead, falling back to a class /
        // canBecomeMain filter (excluding Settings, status item, etc.).
        if let win = NSApp.windows.first(where: { window in
            (window.identifier?.rawValue ?? "").contains("main")
                && window.canBecomeMain
        }) {
            return win
        }
        return NSApp.windows.first { window in
            let className = String(describing: type(of: window))
            return !className.contains("MenuBarExtra")
                && !className.contains("StatusItem")
                && !className.contains("NSStatusBarWindow")
                && !className.contains("PopupBackdrop")
                && !className.contains("Settings")
                && !className.contains("Preferences")
                && window.canBecomeMain
        }
    }

    /// `isVisible` is true for miniaturized and occluded windows, and
    /// `NSApp.isActive` is unreliable in accessory mode — combine the
    /// signals that actually correspond to "user can see pixels."
    private func mainWindowIsShowing() -> Bool {
        guard let win = mainWindow(), win.isVisible, !win.isMiniaturized else {
            return false
        }
        return win.occlusionState.contains(.visible)
    }

    private func toggleMainWindow() {
        if mainWindowIsShowing() {
            // `orderOut` (not `NSApp.hide`) for both modes: hide preserves
            // the window's home Space, so the next activate would yank the
            // user back to that Space. `orderOut` cleanly detaches the
            // window from any Space — the next `makeKeyAndOrderFront` lands
            // it on whatever Space the user is on at that moment.
            mainWindow()?.orderOut(nil)
            return
        }

        // Window flags guarantee it can appear on any Space (incl. fullscreen).
        // Order matters: bring the window forward *first* so it materialises
        // on the current Space — then activate the app. Doing activate first
        // makes macOS jump to wherever the app's key window currently lives,
        // which is exactly the "Space slide" the user wanted to avoid.
        if let win = mainWindow() {
            Self.prepareForCrossSpaceSummon(win)
            if win.isMiniaturized { win.deminiaturize(nil) }
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else if let open = openMainWindow {
            // Closed via red X, or accessory-mode warm path.
            open()
            DispatchQueue.main.async { [weak self] in
                if let w = self?.mainWindow() {
                    Self.prepareForCrossSpaceSummon(w)
                    w.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        } else {
            // Cold accessory-mode path: bridge hasn't installed yet because
            // the WindowGroup has never been materialized. SwiftUI exposes
            // File → New Window via `newWindowForTab:`, which creates a
            // fresh WindowGroup window even with no Dock icon.
            NSApp.sendAction(#selector(NSResponder.newWindowForTab(_:)), to: nil, from: nil)
            DispatchQueue.main.async { [weak self] in
                if let w = self?.mainWindow() {
                    Self.prepareForCrossSpaceSummon(w)
                    w.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
    }

    // MARK: - Menu actions

    @objc private func menuOpen() {
        if let win = mainWindow() {
            Self.prepareForCrossSpaceSummon(win)
            if win.isMiniaturized { win.deminiaturize(nil) }
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else if let open = openMainWindow {
            open()
            DispatchQueue.main.async { [weak self] in
                if let w = self?.mainWindow() {
                    Self.prepareForCrossSpaceSummon(w)
                    w.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        } else {
            NSApp.sendAction(#selector(NSResponder.newWindowForTab(_:)), to: nil, from: nil)
        }
    }

    @objc private func menuPreferences() {
        NSApp.activate(ignoringOtherApps: true)
        // macOS 13+ uses a different selector than the legacy one.
        if NSApp.responds(to: Selector(("showSettingsWindow:"))) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else if NSApp.responds(to: Selector(("showPreferencesWindow:"))) {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }

    @objc private func menuQuit() {
        NSApp.terminate(nil)
    }

    @objc private func menuToggleMenuBarOnly() {
        let new = !isMenuBarOnly()
        UserDefaults.standard.set(new, forKey: "tally.menuBarOnly")
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
        UserDefaults.standard.bool(forKey: "tally.menuBarOnly")
    }

    /// Relaunch Tally cleanly. The only fully reliable way to drop the
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
