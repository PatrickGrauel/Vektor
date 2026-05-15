import SwiftUI
import TallyEngine
import os

enum Pane: String, CaseIterable, Identifiable {
    case calculator   = "Calculator"
    case timezone     = "Timezone"
    case finance      = "Finance"
    case aviation     = "Aviation"
    case map          = "METAR Map"
    case stocks       = "Stocks"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .calculator:   return "function"
        case .timezone:     return "globe"
        case .finance:      return "dollarsign.circle"
        case .aviation:     return "airplane"
        case .map:          return "map"
        case .stocks:       return "chart.line.uptrend.xyaxis"
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
        case .map:                   return "tally.panes.map"
        case .stocks:                return "tally.panes.stocks"
        }
    }

    /// Title for the Settings "Tools" section row.
    var moduleTitle: String {
        switch self {
        case .finance:      return "Finance"
        case .aviation:     return "Aviation"
        case .map:          return "METAR Map"
        case .stocks:       return "Stocks"
        default:            return rawValue
        }
    }

    /// One-liner explaining what the module covers, shown under the toggle.
    var moduleDescription: String {
        switch self {
        case .finance:      return "Loan, mortgage, real-estate deal analysis, tip & split."
        case .aviation:     return "METAR / TAF / ATIS, E6B flight computer, weight & balance."
        case .map:          return "Interactive airport map with live METAR overlay (VFR / MVFR / IFR / LIFR colouring)."
        case .stocks:       return "Score a public company against Warren Buffett's Durable Competitive Advantage framework."
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

    private static let logger = Logger(subsystem: "app.tally.Tally", category: "app-model")

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
    private var fxStreamTask: Task<Void, Never>?
    private var cryptoStreamTask: Task<Void, Never>?
    private var reachabilityObserver: NSObjectProtocol?

    init() {
        do {
            self.engine = try NumiEngine()
        } catch {
            self.engineError = error.localizedDescription
        }
        // Touch the singleton to start NWPathMonitor on launch even if
        // bootstrapLiveData is delayed (e.g. SwiftUI .task latency).
        _ = Reachability.shared
        // On reconnect: kick a fresh FX/crypto fetch + refresh active
        // METAR/TAF/ATIS stations. This is what closes the 5-min worst-
        // case stall after coming back online.
        reachabilityObserver = NotificationCenter.default.addObserver(
            forName: Reachability.reconnectedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Self.logger.info("reachability: reconnected — kicking refresh")
            Task { @MainActor in
                self.refreshActiveStations()
            }
            // FX/Crypto streams' polling tasks pick up on the next tick
            // automatically; nothing more to do here for them — they
            // already use the same shared session that just regained
            // connectivity.
        }
    }

    deinit {
        metarRefreshTask?.cancel()
        fxStreamTask?.cancel()
        cryptoStreamTask?.cancel()
        if let reachabilityObserver {
            NotificationCenter.default.removeObserver(reachabilityObserver)
        }
    }

    func bootstrapLiveData() async {
        // Pick an FX source. OpenExchangeRates if the user has a key,
        // Frankfurter (free ECB rates) otherwise.
        let oxrKey = UserDefaults.standard.string(forKey: "tally.fx.openExchangeRatesKey") ?? ""
        let source: FXService.Source
        if !oxrKey.isEmpty {
            fxSourceLabel = "OpenExchangeRates"
            source = .openExchangeRates(appId: oxrKey)
        } else {
            fxSourceLabel = "Frankfurter (ECB)"
            source = .frankfurter
        }

        // Subscribe to the FX stream. The stream yields the cached
        // snapshot first (if any), then yields again after every
        // successful background refresh — fixes the bug where the engine
        // was stuck on whatever rates landed at launch even after the
        // cache was successfully refreshed in the background.
        fxStreamTask?.cancel()
        fxStreamTask = Task { [weak self] in
            guard let self else { return }
            for await snap in await self.fx.snapshots(using: source) {
                if Task.isCancelled { return }
                await MainActor.run {
                    self.engine?.applyFX(snap)
                    self.fxSnapshotDate = snap.timestamp
                    self.fxCurrencyCount = snap.ratesPerUSD.count
                    self.fxIsOffline = false
                    Self.logger.info("FX stream → engine: \(snap.ratesPerUSD.count) rates, ts=\(snap.timestamp)")
                }
            }
        }

        // Crypto: same stream pattern as FX so any successful background
        // refresh re-applies prices into the engine.
        cryptoStreamTask?.cancel()
        cryptoStreamTask = Task { [weak self] in
            guard let self else { return }
            for await snap in await self.crypto.snapshots() {
                if Task.isCancelled { return }
                await MainActor.run {
                    self.engine?.applyCrypto(snap)
                    Self.logger.info("crypto stream → engine: \(snap.pricesUSD.count) symbols, ts=\(snap.timestamp)")
                }
            }
        }

        startMetarRefreshJob()
    }

    /// Background job that proactively warms METAR/TAF/ATIS for stations
    /// the user has recently referenced.
    ///
    /// Strategy: compute the next expected issuance time across all
    /// active stations using `NumiEngine.nextExpectedIssuance(…)` — for
    /// METAR that's the next :55 of the hour, for TAF the next 0/6/12/18
    /// UTC slot, for ATIS roughly one hour after the cached observation
    /// — sleep until then, refresh, repeat. This is dramatically tighter
    /// than blind 5-min polling and is also gentler on the upstream API.
    ///
    /// A 5-min ticker remains as a backstop in case the precise-schedule
    /// task is cancelled (sleep/wake on a laptop) or upstream runs late.
    private func startMetarRefreshJob() {
        metarRefreshTask?.cancel()
        metarRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }

                // Schedule-on-issuance leg: sleep until the earliest
                // expected issuance across active stations. If nothing
                // is active, fall back to the backstop interval.
                let now = Date()
                let stations = MetarCacheBridge.shared.activeStations()
                let target: Date = {
                    var earliest: Date = now.addingTimeInterval(AppModel.refreshJobInterval)
                    for (kind, icao) in stations {
                        let cachedRaw = MetarCacheBridge.shared.cached(kind: kind, icao: icao)?.raw
                        let next = NumiEngine.nextExpectedIssuance(for: kind, rawCached: cachedRaw, after: now)
                        if next < earliest { earliest = next }
                    }
                    // Never sleep less than 30 s — guards against a
                    // tight loop if a station's expected issuance is in
                    // the very near past (clock skew).
                    return max(earliest, now.addingTimeInterval(30))
                }()

                let sleepInterval = target.timeIntervalSince(Date())
                if sleepInterval > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(sleepInterval * 1_000_000_000))
                }
                if Task.isCancelled { return }
                self.refreshActiveStations()
            }
        }
    }

    func refreshActiveStations() {
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
    @AppStorage("tally.panes.map")          private var enableMap          = true
    // Stocks defaults to OFF — pulling financial data needs the user's
    // FMP API key, which is an explicit opt-in, so the pane stays hidden
    // until the user enables it in Settings.
    @AppStorage("tally.panes.stocks")       private var enableStocks       = false

    /// Panes currently visible in the dropdown — core panes are always
    /// included, the rest are filtered by the per-module Settings toggles.
    private var visiblePanes: [Pane] {
        Pane.allCases.filter { pane in
            switch pane {
            case .calculator, .timezone: return true
            case .finance:               return enableFinance
            case .aviation:              return enableAviation
            case .map:                   return enableMap
            case .stocks:                return enableStocks
            }
        }
    }

    var body: some View {
        paneContent
            // Suppress the auto-rendered title text; a principal toolbar
            // item below draws "Tally" with custom typography so it matches
            // the SHEET chrome label. The WindowGroup("Tally") name still
            // surfaces in the Window menu / Dock / app switcher.
            .navigationTitle("")
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

                // "Tally" centered in the toolbar — rendered in the
                // default title weight (semibold, matching the native
                // window title) and half-translucent so the wordmark
                // reads as a quiet anchor rather than competing with
                // the active pane.
                ToolbarItem(placement: .principal) {
                    Text("Tally")
                        .fontWeight(.semibold)
                        .opacity(0.5)
                        .accessibilityHidden(true)
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
        case .map:          MapPane()
        case .stocks:       StocksPane()
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
