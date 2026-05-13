import SwiftUI
import TallyEngine

enum Pane: String, CaseIterable, Identifiable {
    case calculator   = "Calculator"
    case timezone     = "Timezone"
    case finance      = "Finance"
    case aviation     = "Aviation"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .calculator:   return "function"
        case .timezone:     return "globe"
        case .finance:      return "dollarsign.circle"
        case .aviation:     return "airplane"
        }
    }

    /// Always-visible panes — the universal calculator surface plus the
    /// timezone tool everyone uses. The rest are domain modules the user
    /// opts into from Settings.
    var isCore: Bool {
        switch self {
        case .calculator, .timezone: return true
        default:                     return false
        }
    }

    /// UserDefaults key used to gate a module pane. Core panes have no key
    /// and ignore the toggle.
    var enabledKey: String? {
        switch self {
        case .calculator, .timezone: return nil
        case .finance:               return "tally.panes.finance"
        case .aviation:              return "tally.panes.aviation"
        }
    }

    /// Title for the Settings "Tools" section row.
    var moduleTitle: String {
        switch self {
        case .finance:      return "Finance"
        case .aviation:     return "Aviation"
        default:            return rawValue
        }
    }

    /// One-liner explaining what the module covers, shown under the toggle.
    var moduleDescription: String {
        switch self {
        case .finance:      return "Loan, mortgage, real-estate deal analysis, tip & split."
        case .aviation:     return "METAR / TAF / ATIS, E6B flight computer, weight & balance."
        default:            return ""
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var engine: NumiEngine?
    @Published var engineError: String?
    @Published var fxSnapshotDate: Date?
    @Published var fxCurrencyCount: Int = 0
    @Published var fxSourceLabel: String = "Not configured"
    @Published var fxIsOffline: Bool = false

    private let fx = FXService()
    private let crypto = CryptoService()
    /// Per-kind staleness thresholds for the background refresh job. METARs
    /// re-issue every 30–60 min (with SPECI between), TAFs change a handful
    /// of times per day, ATIS letters tick ~hourly.
    private static let metarRefreshAfter: TimeInterval = 5 * 60
    private static let tafRefreshAfter:   TimeInterval = 30 * 60
    private static let atisRefreshAfter:  TimeInterval = 60 * 60
    private static let refreshJobInterval: TimeInterval = 5 * 60
    private var metarRefreshTask: Task<Void, Never>?

    init() {
        do {
            self.engine = try NumiEngine()
        } catch {
            self.engineError = error.localizedDescription
        }
    }

    deinit {
        metarRefreshTask?.cancel()
    }

    func bootstrapLiveData() async {
        let oxrKey = UserDefaults.standard.string(forKey: "tally.fx.openExchangeRatesKey") ?? ""
        if !oxrKey.isEmpty {
            fxSourceLabel = "OpenExchangeRates"
            if let snap = await fx.snapshot(using: .openExchangeRates(appId: oxrKey)) {
                engine?.applyFX(snap)
                fxSnapshotDate = snap.timestamp
                fxCurrencyCount = snap.ratesPerUSD.count
                fxIsOffline = false
            } else {
                fxIsOffline = true
            }
        } else {
            // No OXR key — fall back to Frankfurter (free ECB rates, ~30 majors
            // including HUF, CZK, PLN). Real-time enough for a calculator app.
            fxSourceLabel = "Frankfurter (ECB)"
            if let snap = await fx.snapshot(using: .frankfurter) {
                engine?.applyFX(snap)
                fxSnapshotDate = snap.timestamp
                fxCurrencyCount = snap.ratesPerUSD.count
                fxIsOffline = false
            } else {
                fxIsOffline = true
            }
        }
        if let cryptoSnap = await crypto.snapshot() {
            engine?.applyCrypto(cryptoSnap)
        }
        startMetarRefreshJob()
    }

    /// Background job that proactively warms METAR/TAF/ATIS for stations
    /// the user has recently referenced (in the open document or the
    /// Aviation pane). Runs every 5 minutes; each prefetch is deduped by
    /// the bridge's own cooldown, so racing with the Aviation pane's own
    /// refresh timer is harmless.
    private func startMetarRefreshJob() {
        metarRefreshTask?.cancel()
        metarRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(AppModel.refreshJobInterval * 1_000_000_000))
                guard let self else { return }
                self.refreshActiveStations()
            }
        }
    }

    private func refreshActiveStations() {
        let bridge = MetarCacheBridge.shared
        let now = Date()
        for (kind, icao) in bridge.activeStations() {
            // Per-kind staleness: only kick a refresh if this entry has
            // aged past its kind's threshold. Otherwise the bridge would
            // mostly short-circuit on its 5-min cooldown anyway, but this
            // saves a few cycles and keeps the intent explicit.
            let threshold: TimeInterval
            switch kind {
            case .metar: threshold = AppModel.metarRefreshAfter
            case .taf:   threshold = AppModel.tafRefreshAfter
            case .atis:  threshold = AppModel.atisRefreshAfter
            }
            if let cached = bridge.cached(kind: kind, icao: icao),
               now.timeIntervalSince(cached.fetchedAt) < threshold {
                continue
            }
            bridge.prefetch(kind: kind, icao: icao)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var documents = DocumentStore()
    @StateObject private var calculatorBridge = CalculatorBridge()
    @State private var selection: Pane = .calculator
    @State private var showPaneMenu = false
    @State private var showDocsPopover = false
    @AppStorage("tally.appearance") private var appearance: String = "system"

    // Per-module enabled flags. Default to true so existing users don't
    // lose features after an update; new users can trim the menu down
    // from Settings.
    @AppStorage("tally.panes.finance")      private var enableFinance      = true
    @AppStorage("tally.panes.aviation")     private var enableAviation     = true

    /// Panes currently visible in the dropdown — core panes are always
    /// included, the rest are filtered by the per-module Settings toggles.
    private var visiblePanes: [Pane] {
        Pane.allCases.filter { pane in
            switch pane {
            case .calculator, .timezone: return true
            case .finance:               return enableFinance
            case .aviation:              return enableAviation
            }
        }
    }

    var body: some View {
        paneContent
            // Let the WindowGroup("Tally") title surface in the title bar
            // — macOS renders it centered above the toolbar, matching
            // Numi-style.
            .navigationTitle("Tally")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(TallyTheme.background.ignoresSafeArea())
            .toolbarBackground(TallyTheme.background, for: .windowToolbar)
            .toolbarBackground(.visible, for: .windowToolbar)
            .preferredColorScheme(colorScheme(for: appearance))
            .environmentObject(calculatorBridge)
            .task { await model.bootstrapLiveData() }
            .onAppear {
                // Install the cross-pane "Send to Calculator" implementation
                // here, where we have access to both the documents and the
                // pane selection. Other panes call `bridge.send(label, value)`
                // from any tab and we route it correctly.
                calculatorBridge.send = { [weak documents] label, value in
                    guard let documents else { return }
                    let existing = documents.selected.content
                    let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
                    let appended = """
                    \(separator)
                    # \(label)
                    \(value)
                    """
                    documents.updateSelectedContent(existing + appended)
                    selection = .calculator
                }
            }
            // If the user disables the module they're currently viewing,
            // bounce back to Calculator so they don't end up looking at a
            // pane that's been removed from the menu.
            .onChange(of: visiblePanes) { _, panes in
                if !panes.contains(selection) {
                    selection = .calculator
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Menu {
                        ForEach(Array(visiblePanes.enumerated()), id: \.element) { idx, pane in
                            Button {
                                selection = pane
                            } label: {
                                // Keep the pane's icon visible AND mark the
                                // current selection — replacing the icon with
                                // a checkmark robbed the menu of the at-a-
                                // glance scan that the icons enable.
                                HStack(spacing: 8) {
                                    Image(systemName: pane.icon)
                                    Text(pane.rawValue)
                                    Spacer()
                                    if pane == selection {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(TallyTheme.accent)
                                    }
                                }
                            }
                            // ⌘1..⌘9 quick-switch — only bind on indices the
                            // user can actually press; saves an Apple-flag
                            // collision on ⌘0.
                            .keyboardShortcut(idx < 9 ? KeyEquivalent(Character("\(idx + 1)")) : .return,
                                              modifiers: idx < 9 ? .command : [.command, .option])
                        }
                    } label: {
                        // Show the current pane's icon so the toolbar reflects
                        // where you are. Calculator stays on the brand glyph;
                        // every other pane uses its SF symbol.
                        Group {
                            if selection == .calculator {
                                Image(nsImage: TallyGlyph.nsImage(
                                    size: 18,
                                    color: NSColor(TallyTheme.accent)
                                ))
                                .renderingMode(.original)
                            } else {
                                Image(systemName: selection.icon)
                                    .imageScale(.large)
                                    .foregroundStyle(TallyTheme.text)
                            }
                        }
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .help("Switch pane — currently \(selection.rawValue)")
                    .accessibilityLabel("Switch pane")
                    .accessibilityValue(selection.rawValue)
                }

                // Calculator-specific actions sit at the top-right of the
                // window toolbar, on the same row as the traffic lights and
                // the pane-picker glyph on the left. Both are wrapped in
                // a `Menu` with `.menuStyle(.borderlessButton)` so they
                // inherit the same minimal chrome the pane glyph uses,
                // rather than the heavy "glass capsule" that `.primaryAction`
                // Button items get by default.
                if selection == .calculator {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button("New calculation") { _ = documents.newDocument() }
                                .keyboardShortcut("n", modifiers: .command)
                        } label: {
                            Image(systemName: "plus")
                                .imageScale(.large)
                                .foregroundStyle(TallyTheme.text)
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        } primaryAction: {
                            _ = documents.newDocument()
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .help("New calculation (⌘N)")
                        .accessibilityLabel("New calculation")
                    }

                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button("Show all calculations") { showDocsPopover = true }
                                .keyboardShortcut("l", modifiers: .command)
                        } label: {
                            Image(systemName: "line.3.horizontal")
                                .imageScale(.large)
                                .foregroundStyle(TallyTheme.text)
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        } primaryAction: {
                            showDocsPopover = true
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .help("Show all calculations (⌘L)")
                        .accessibilityLabel("Show all calculations")
                        .popover(isPresented: $showDocsPopover, arrowEdge: .bottom) {
                            DocumentsPopover(store: documents, isPresented: $showDocsPopover)
                        }
                    }
                }
            }
    }

    @ViewBuilder
    private var paneContent: some View {
        switch selection {
        case .calculator:   CalculatorPane(engine: model.engine, error: model.engineError, documents: documents)
        case .timezone:     TimezoneView()
        case .finance:      FinancePane()
        case .aviation:     AviationPane()
        }
    }

    private func colorScheme(for raw: String) -> ColorScheme? {
        switch raw {
        case "light": return .light
        case "dark":  return .dark
        default:      return nil   // follow system
        }
    }
}

#Preview { ContentView().environmentObject(AppModel()) }
