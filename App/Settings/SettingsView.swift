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


    // Module pane visibility — each toggle hides/shows the corresponding
    // pane in the top-left dropdown. Defaults match what new users got
    // before this setting existed, so nothing disappears after upgrade.
    @AppStorage("tally.panes.finance")      private var enableFinance      = true
    @AppStorage("tally.panes.aviation")     private var enableAviation     = true
    @AppStorage("tally.panes.stocks")       private var enableStocks       = false

    // Advanced — collapsed by default. The FMP API key powers the
    // Stocks pane. Stored in UserDefaults as part of `tally.stocks.*`.
    @AppStorage("tally.stocks.fmpApiKey")   private var fmpApiKey: String = ""
    @State private var showAdvanced: Bool = false

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

            // MARK: Tools — pane visibility
            Section {
                Toggle(Pane.finance.moduleTitle, isOn: $enableFinance)
                Text(Pane.finance.moduleDescription)
                    .font(.caption).foregroundStyle(.secondary)

                Toggle(Pane.aviation.moduleTitle, isOn: $enableAviation)
                Text(Pane.aviation.moduleDescription)
                    .font(.caption).foregroundStyle(.secondary)

                Toggle(Pane.stocks.moduleTitle, isOn: $enableStocks)
                Text(Pane.stocks.moduleDescription)
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Tools")
            } footer: {
                Text("Turn off tools you don't use to keep the top-left menu tidy. Calculator and Timezone are always available.")
                    .font(.caption).foregroundStyle(.secondary)
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

            // MARK: Advanced — collapsed by default, hosts the API keys
            // that don't fit anywhere else (currently just FMP for the
            // Stocks pane). Tapping the header expands / collapses.
            Section {
                DisclosureGroup(isExpanded: $showAdvanced) {
                    LabeledContent("FMP API key") {
                        SecureField("", text: $fmpApiKey)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 260)
                            .onChange(of: fmpApiKey) { _, new in
                                Task { await FMPClient.shared.setAPIKey(new.isEmpty ? nil : new) }
                            }
                    }
                    Text("Financial Modeling Prep powers the Stocks pane. The free tier covers about 50 analyses per day. [Get a key](https://site.financialmodelingprep.com/developer/docs)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } label: {
                    Label("Advanced", systemImage: "wrench.and.screwdriver")
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
