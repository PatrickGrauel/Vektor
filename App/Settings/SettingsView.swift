import SwiftUI
import AppKit
import VektorEngine

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var ent: EntitlementManager

    // General
    @AppStorage("vektor.precision")  private var precision: Int = 2
    @AppStorage("vektor.appearance") private var appearance: String = "system"
    @AppStorage("vektor.menuBarOnly") private var menuBarOnly: Bool = false
    @AppStorage("vektor.fx.showProvenance") private var showFXProvenance: Bool = true
    @AppStorage(DigitGrouping.defaultsKey) private var digitGrouping: Bool = true
    @AppStorage("vektor.calc.syntaxColoring") private var syntaxColoring: Bool = true
    @State private var launchAtLogin: Bool = LaunchAtLogin.isEnabled
    @AppStorage("vektor.alwaysOnTop") private var alwaysOnTop: Bool = false
    @State private var showDocs: Bool = false
    @State private var showLicenses: Bool = false

    // Units (preferences shared across all panes that care)
    @AppStorage("vektor.aviation.speedUnit")    private var speedUnit: String = "kt"
    @AppStorage("vektor.aviation.altitudeUnit") private var altitudeUnit: String = "ft"
    @AppStorage("vektor.aviation.pressureUnit") private var pressureUnit: String = "hPa"


    // Stocks visibility — kept here only to gate the Settings → Stocks
    // section below (the API-key / plan / cap surface, which makes
    // sense only when the pane is enabled). Pane-visibility toggles
    // themselves live in the pane menu's "Manage panes…" popover.
    @AppStorage("vektor.panes.stocks") private var enableStocks = false

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
                Toggle("Colour calculations", isOn: $syntaxColoring)
                    .help("Uses blue for variables, violet for units and currencies, and orange for math operators in the calculator editor.")
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        if !LaunchAtLogin.setEnabled(newValue) {
                            // Revert UI if the system rejected the change.
                            launchAtLogin = LaunchAtLogin.isEnabled
                        }
                    }
                Toggle("Show currency rate source", isOn: $showFXProvenance)
                Toggle("Space out large numbers while typing", isOn: $digitGrouping)
                    .help("Visually groups 5+ digit numbers (12 000) in the editor. The text itself is unchanged.")
                Text("Tags currency results with their rate source — e.g. \u{201C}ECB\u{201D}. ECB publishes one official reference rate per business day, so results can differ slightly from live tickers. Currencies the ECB doesn't publish (e.g. RUB) come from ExchangeRate-API, crypto prices from CoinGecko.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Always on top", isOn: $alwaysOnTop)
                Toggle("Menu Bar Only Mode", isOn: $menuBarOnly)
                    .onChange(of: menuBarOnly) { _, _ in
                        MenuBarController.shared.applyActivationPolicy()
                    }
                Text("Menu Bar Only Mode hides the Dock icon; reopen Vektor by clicking the menu bar icon. macOS sometimes leaves the Dock icon visible until the next launch — use **Relaunch Vektor** below if it sticks.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Relaunch Vektor") {
                        MenuBarController.shared.relaunch()
                    }
                    .help("Quit and reopen Vektor. The cleanest way to apply Menu Bar Only Mode if the Dock icon doesn't disappear.")
                }
            }

            // MARK: License
            Section("Vektor Calculator") {
                LabeledContent("Status") {
                    Text(ent.statusText)
                        .foregroundStyle(ent.isPurchased ? Color.green : .secondary)
                }
                if !ent.isPurchased {
                    Text("60 days free, then a one-time lifetime unlock through the App Store. No subscription or automatic charge.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button {
                        Task { await ent.purchase() }
                    } label: {
                        Text(ent.product.map { "Unlock for life — \($0.displayPrice)" } ?? "Unlock for life")
                    }
                    .disabled(ent.isBusy || ent.accessState == .checking || ent.product == nil)
                }
                Button(ent.restoreInFlight ? "Restoring purchases…" : "Restore Purchases") { Task { await ent.restore() } }
                    .disabled(ent.isBusy)
                if ent.isLoadingProducts {
                    ProgressView("Loading App Store prices…").controlSize(.small)
                } else if ent.product == nil {
                    Button("Retry App Store connection") { Task { await ent.loadProduct() } }
                        .disabled(ent.isBusy)
                }
                if let err = ent.lastErrorMessage {
                    Text(err).font(.caption).foregroundStyle(.red)
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
                    Text("Your key stays on this Mac. Vektor only sends it to financialmodelingprep.com when you analyse a ticker.")
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
                    Link("Support", destination: ReleaseLinks.support)
                    Spacer()
                    Text("Vektor \(Bundle.main.shortVersion) (\(Bundle.main.buildVersion))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Link("Privacy policy", destination: ReleaseLinks.privacy)
                    Link("Terms", destination: ReleaseLinks.terms)
                    Button("Open-source licenses") { showLicenses = true }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(width: 480, height: 540)
        // `themedSheet` applies VektorTheme.background AND the user's
        // light/dark preference. Without it the Settings window ignores
        // the Appearance picker the user just changed.
        .themedSheet()
        .background(WindowLevelApplier(alwaysOnTop: alwaysOnTop))
        .sheet(isPresented: $showDocs) {
            DocumentationView()
        }
        .sheet(isPresented: $showLicenses) {
            LicensesView()
        }
    }
}

/// Pins the host window to .floating when Always-on-Top is on, matching
/// the main Vektor window so Settings doesn't end up hidden behind it.
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
