import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    // General
    @AppStorage("tally.precision")  private var precision: Int = 14
    @AppStorage("tally.appearance") private var appearance: String = "system"
    @AppStorage("tally.menuBarOnly") private var menuBarOnly: Bool = false
    @State private var launchAtLogin: Bool = LaunchAtLogin.isEnabled
    @AppStorage("tally.alwaysOnTop") private var alwaysOnTop: Bool = false
    @State private var showDocs: Bool = false

    // Units (preferences shared across all panes that care)
    @AppStorage("tally.aviation.speedUnit")    private var speedUnit: String = "kt"
    @AppStorage("tally.aviation.altitudeUnit") private var altitudeUnit: String = "ft"
    @AppStorage("tally.aviation.pressureUnit") private var pressureUnit: String = "hPa"


    // Stocks visibility — kept here only to gate the Settings → Stocks
    // section below (the API-key / plan / cap surface, which makes
    // sense only when the pane is enabled). Pane-visibility toggles
    // themselves live in the pane menu's "Manage panes…" popover.
    @AppStorage("tally.panes.stocks") private var enableStocks = false

    // Stocks management UI lives in StocksManageView (shared with the
    // pane's footer popover). The bindings flow into UserDefaults so
    // both surfaces stay in sync — no local state needed here.

    var body: some View {
        Form {
            // MARK: General
            Section("General") {
                LabeledContent("Precision") {
                    HStack(spacing: 6) {
                        TextField("", value: $precision, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 48)
                            .multilineTextAlignment(.center)
                        Stepper("", value: $precision, in: 0...14).labelsHidden()
                        Text("decimal places")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Picker("Appearance", selection: $appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        if !LaunchAtLogin.setEnabled(newValue) {
                            // Revert UI if the system rejected the change.
                            launchAtLogin = LaunchAtLogin.isEnabled
                        }
                    }
                Toggle("Always on top", isOn: $alwaysOnTop)
                Toggle("Menu Bar Only Mode", isOn: $menuBarOnly)
                    .onChange(of: menuBarOnly) { _, _ in
                        MenuBarController.shared.applyActivationPolicy()
                    }
                Text("Menu Bar Only Mode hides the Dock icon; reopen Tally by clicking the menu bar icon. macOS sometimes leaves the Dock icon visible until the next launch — use **Relaunch Tally** below if it sticks.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Relaunch Tally") {
                        MenuBarController.shared.relaunch()
                    }
                    .help("Quit and reopen Tally. The cleanest way to apply Menu Bar Only Mode if the Dock icon doesn't disappear.")
                }
            }

            // MARK: Units
            Section("Units") {
                Picker("Speed",    selection: $speedUnit) {
                    Text("Knots").tag("kt")
                    Text("MPH").tag("mph")
                    Text("km/h").tag("kph")
                }
                Picker("Altitude", selection: $altitudeUnit) {
                    Text("Feet").tag("ft")
                    Text("Meters").tag("m")
                }
                Picker("Pressure", selection: $pressureUnit) {
                    Text("hPa").tag("hPa")
                    Text("inHg").tag("inHg")
                }
            }

            // MARK: Stocks — only appears when the Stocks pane is on.
            // Same management surface as the in-pane popover; both are
            // bindings on the same UserDefaults so they stay in sync.
            if enableStocks {
                Section {
                    StocksManageView(titleVisible: false)
                } header: {
                    Text("Stocks")
                } footer: {
                    Text("Your key stays on this Mac. Tally only sends it to financialmodelingprep.com when you analyse a ticker.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // MARK: Footer
            Section {
                HStack {
                    Button {
                        showDocs = true
                    } label: {
                        Label("Documentation", systemImage: "book")
                    }
                    Button("Send feedback") {
                        if let url = URL(string: "mailto:feedback@tally.app?subject=Tally%20feedback") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Spacer()
                    Text("Tally \(Bundle.main.shortVersion) (\(Bundle.main.buildVersion))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(width: 480, height: 540)
        // `themedSheet` applies TallyTheme.background AND the user's
        // light/dark preference. Without it the Settings window ignores
        // the Appearance picker the user just changed.
        .themedSheet()
        .background(WindowLevelApplier(alwaysOnTop: alwaysOnTop))
        .sheet(isPresented: $showDocs) {
            DocumentationView()
        }
    }
}

/// Pins the host window to .floating when Always-on-Top is on, matching
/// the main Tally window so Settings doesn't end up hidden behind it.
private struct WindowLevelApplier: NSViewRepresentable {
    let alwaysOnTop: Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            let desired: NSWindow.Level = alwaysOnTop ? .floating : .normal
            if window.level != desired { window.level = desired }
        }
    }
}

private extension Bundle {
    var shortVersion: String {
        (object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.1"
    }
    var buildVersion: String {
        (object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "1"
    }
}
