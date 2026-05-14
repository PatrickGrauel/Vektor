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

    // FAA NOTAM Search API credentials. Register a free account at
    // https://api.faa.gov, create an app, paste the resulting
    // client_id and client_secret here. Without them the `NOTAM ICAO`
    // calculator command renders an "unauthenticated" message.
    @AppStorage("tally.notam.faaClientId")      private var faaClientId: String = ""
    @AppStorage("tally.notam.faaClientSecret")  private var faaClientSecret: String = ""

    // Module pane visibility — each toggle hides/shows the corresponding
    // pane in the top-left dropdown. Defaults match what new users got
    // before this setting existed, so nothing disappears after upgrade.
    @AppStorage("tally.panes.finance")      private var enableFinance      = true
    @AppStorage("tally.panes.aviation")     private var enableAviation     = true

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

            // MARK: NOTAM credentials
            Section {
                LabeledContent("Client ID") {
                    TextField("", text: $faaClientId, prompt: Text("paste your client_id"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                }
                LabeledContent("Client Secret") {
                    SecureField("", text: $faaClientSecret, prompt: Text("paste your client_secret"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                }
                HStack {
                    Spacer()
                    Button("Open FAA developer portal") {
                        if let url = URL(string: "https://api.faa.gov") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            } header: {
                Text("NOTAMs (FAA API)")
            } footer: {
                Text("Tally fetches NOTAMs from the FAA NOTAM Search API. The credentials are free — register an app at api.faa.gov, then paste the client_id and client_secret here. Without them the `NOTAM EDDM` calculator command shows an authentication prompt.")
                    .font(.caption).foregroundStyle(.secondary)
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
