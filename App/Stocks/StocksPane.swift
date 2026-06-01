import SwiftUI
import AppKit

/// Stocks pane — analyse a public company against Warren Buffett's
/// "Durable Competitive Advantage" framework. Pulls five years of
/// financials from financialmodelingprep.com, scores six axes 0–10, and
/// renders both a textual scorecard and a radar chart.
struct StocksPane: View {
    /// Persistent state for this pane — survives navigation away/back so
    /// a loaded scorecard isn't thrown out when the user pops over to
    /// the Calculator. Owned by ContentView, passed in here.
    @ObservedObject var session: StocksPaneSession

    @AppStorage("vektor.stocks.recentTickers") private var recentTickersRaw: String = ""
    /// Whether an FMP key is currently stored. Mirrored into UserDefaults
    /// by `KeychainStorage.set/delete` so we can answer "is the user set
    /// up?" without ever reading the Keychain — which would trigger a
    /// system prompt on every ad-hoc build. The actual key value is
    /// read only at API-call time inside FMPClient.
    @AppStorage("vektor.stocks.fmpApiKey.present") private var hasFMPKey: Bool = false
    // Observe the plan + custom-cap settings so the footer's daily-cap
    // number reflects the user's current plan in real time. Without
    // this, changing the plan in the manage popover refreshes that
    // view's local budget snapshot but leaves the pane's footer state
    // showing the old (free-tier) cap.
    @AppStorage(FMPPlan.storageKey) private var planRaw: String = FMPPlan.free.rawValue
    @AppStorage(FMPPlan.customCapKey) private var customCap: Int = 240
    @StateObject private var monitor = StocksConnectionMonitor.shared

    @State private var budget: FMPClient.BudgetSnapshot?
    /// Typeahead state — when the user types something more like a
    /// name than a ticker (e.g. "Tesla") we debounce a fuzzy search
    /// against FMP and show matches in a popover. Search popover state
    /// is intentionally NOT in the session — it's transient UI that
    /// should reset every time you come back to the pane.
    @State private var searchHits: [FMPClient.SearchHit] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var showSuggestions = false
    /// Manage popover — the in-pane shortcut to the key / plan / usage
    /// view, anchored to the footer status bar.
    @State private var showManage = false

    private var recents: [String] {
        recentTickersRaw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        Form {
            if !hasFMPKey {
                // First-run / not-yet-keyed flow — the pane owns its
                // setup so the user doesn't have to spelunk Settings to
                // discover what FMP is or why a Mac app wants a key.
                setupCardSection
            } else {
                if !session.watchlist.tickers.isEmpty {
                    watchlistSection
                }

                inputSection

                if let err = session.analysisError {
                    errorSection(for: err)
                }

                if session.loading {
                    Section {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Pulling financials from FMP…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let card = session.scorecard {
                    resultsSections(card: card)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(VektorTheme.background)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            footerBar
        }
        .onAppear {
            // Session hydrates `ticker` from UserDefaults at init time,
            // so the input box is already populated when we get here.
            // Scorecard survives via the session too — no re-analysis
            // needed if the user just popped over to another pane.
            Task { await refreshBudget() }
            // Best-effort watchlist quote refresh. Internal stale-window
            // (5 min) prevents re-hitting on rapid re-opens.
            if hasFMPKey {
                Task { await session.watchlist.refreshIfStale() }
            }
        }
        .onChange(of: hasFMPKey) { _, present in
            // Sync the connection-status indicator + FMPClient's cached
            // key. When the boolean flips from false→true, FMPClient
            // re-reads the Keychain on its next request (triggering the
            // one-time prompt at use-the-key time, not now). When it
            // flips true→false, we clear FMPClient's cache eagerly.
            monitor.reflectKeyPresence(present: present)
            if !present {
                Task { await FMPClient.shared.setAPIKey(nil) }
            } else {
                Task { await FMPClient.shared.refreshAPIKeyFromKeychain() }
            }
        }
        // Plan / custom-cap changes don't fire a network call, but they
        // do change the effective `callsLimit` reported by FMPClient —
        // so refresh the footer's budget snapshot to pick up the new
        // ceiling immediately.
        .onChange(of: planRaw) { _, _ in
            Task { await refreshBudget() }
        }
        .onChange(of: customCap) { _, _ in
            Task { await refreshBudget() }
        }
        // No onDisappear cancellation: an in-flight analysis lives on
        // the session, so switching panes mid-fetch lets it finish in
        // the background. The user comes back to a populated scorecard
        // instead of having to re-trigger.
    }

    // MARK: - Setup card

    /// Setup state shown when no key is set. Explains what FMP is, why
    /// Vektor needs a key, and offers a one-click link to get one — all
    /// inline so the user never has to leave the pane to enable it.
    @State private var pastedKey: String = ""

    private var setupCardSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(VektorTheme.accent)
                    Text("Connect a data source — optional")
                        .font(.headline)
                }
                Text("Stocks is **optional**. The rest of Vektor — calculator, units, currencies, METAR, timezones — works without any account or key.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text("If you want stock data, Vektor pulls financial statements from **Financial Modeling Prep**, a third-party provider. You'll need a free FMP account — their free plan covers around 50 analyses per day of major US-listed companies.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button {
                        openURL("https://site.financialmodelingprep.com/developer/docs")
                    } label: {
                        Label("Get a free key", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(VektorTheme.accent)
                    SecureField("Paste your FMP key here", text: $pastedKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 220)
                    Button("Connect") {
                        let trimmed = pastedKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        // Direct Keychain write — silent for the app's
                        // own new items. The presence boolean flips
                        // automatically via KeychainStorage.set, which
                        // wakes the `.onChange(of: hasFMPKey)` observer
                        // above to wire up FMPClient.
                        KeychainStorage.set(trimmed, for: "vektor.stocks.fmpApiKey")
                        pastedKey = ""
                    }
                    .disabled(pastedKey.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("Need international markets or full S&P 500 coverage? FMP's paid plans start around $14/month. [See plans →](https://site.financialmodelingprep.com/developer/docs/pricing)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        } header: {
            Text("Stocks")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Your key stays on this Mac. Vektor stores it in the macOS **Keychain** — so it's encrypted at rest instead of sitting in a preferences file. The first time you save it, macOS may show a one-time *“Vektor wants to use the keychain”* prompt; click **Always Allow** and you won't see it again. Vektor never sends the key anywhere except to financialmodelingprep.com.")
                Text("Change or remove it later in Settings → Stocks.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Input + recents

    private var inputSection: some View {
        Section {
            LabeledContent("Ticker or company") {
                HStack(spacing: 8) {
                    TextField("", text: $session.ticker, prompt: Text("Tesla, KO, AAPL…"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .labelsHidden()
                        .onChange(of: session.ticker) { _, new in
                            // Don't upper-case on every keystroke any
                            // more — typeahead needs lowercase queries
                            // to work ("Tesla" → matches). analyse()
                            // upper-cases before sending to FMP.
                            scheduleSearch(query: new)
                        }
                        .onSubmit { analyse() }
                        .popover(isPresented: $showSuggestions,
                                 attachmentAnchor: .rect(.bounds),
                                 arrowEdge: .bottom) {
                            suggestionsList
                                .frame(width: 320)
                                .padding(.vertical, 4)
                        }
                    Button("Analyze") { analyse() }
                        .keyboardShortcut(.return, modifiers: [])
                        .disabled(session.ticker.trimmingCharacters(in: .whitespaces).isEmpty || session.loading)
                    watchlistStarButton
                }
            }
            if !recents.isEmpty {
                LabeledContent("Recent") {
                    HStack(spacing: 6) {
                        ForEach(recents, id: \.self) { t in
                            Button(t) {
                                session.ticker = t
                                analyse()
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(VektorTheme.codeSurface)
                            .clipShape(Capsule())
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(VektorTheme.text)
                        }
                        Spacer()
                    }
                }
            }
        } footer: {
            Text("Buffett's *Durable Competitive Advantage* framework, six axes scored 0–10. The free FMP tier returns five years of statements; the framework's 10-year tests are applied to that shorter window and flagged in the rationale.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Radar legend

    /// Small caption under the radar chart explaining the dashed band.
    /// Two lozenges (one for the data polygon, one for the benchmark
    /// band) act as a tiny inline legend so users don't have to guess
    /// what the muted dashed shape means.
    private var radarBenchmarkLegend: some View {
        HStack(spacing: 14) {
            legendSwatch(color: VektorTheme.accent,
                         dashed: false,
                         label: "This ticker")
            legendSwatch(color: VektorTheme.muted.opacity(0.65),
                         dashed: true,
                         label: "Buffett-quality baseline (7/10)")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.bottom, 6)
        .help("Every axis poking outside the dashed band meets a generic Buffett-quality threshold (score ≥ 7). Axes inside the band are under-performing on that dimension.")
    }

    private func legendSwatch(color: Color, dashed: Bool, label: String) -> some View {
        HStack(spacing: 5) {
            Canvas { ctx, size in
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height / 2))
                path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                let style = dashed
                    ? StrokeStyle(lineWidth: 1.2, dash: [3, 3])
                    : StrokeStyle(lineWidth: 1.5)
                ctx.stroke(path, with: .color(color), style: style)
            }
            .frame(width: 18, height: 4)
            Text(label)
        }
    }

    // MARK: - Watchlist

    /// Star icon next to the Analyze button. Toggle for "is this ticker
    /// in my watchlist?" — filled accent when starred, hollow muted
    /// when not. Disabled when the input is empty.
    private var watchlistStarButton: some View {
        let trimmed = session.ticker.trimmingCharacters(in: .whitespaces).uppercased()
        let isStarred = session.watchlist.contains(trimmed)
        return Button {
            session.watchlist.toggle(trimmed)
        } label: {
            Image(systemName: isStarred ? "star.fill" : "star")
                .imageScale(.medium)
                .foregroundStyle(isStarred ? VektorTheme.accent : VektorTheme.muted)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(trimmed.isEmpty)
        .help(isStarred ? "Remove from watchlist" : "Add to watchlist")
        .accessibilityLabel(isStarred ? "Remove from watchlist" : "Add to watchlist")
    }

    /// Watchlist grid + refresh control. Rendered only when there's at
    /// least one starred ticker, so the pane stays clean for users who
    /// haven't starred anything yet.
    private var watchlistSection: some View {
        Section {
            WatchlistGrid(
                tickers: session.watchlist.tickers,
                quotes: session.watchlist.quotes,
                currentTicker: session.ticker.trimmingCharacters(in: .whitespaces).uppercased(),
                onSelect: { t in
                    session.ticker = t
                    analyse()
                },
                onUnstar: { t in
                    session.watchlist.remove(t)
                }
            )
            .padding(.vertical, 2)
        } header: {
            HStack(spacing: 8) {
                Text("Watchlist")
                Spacer(minLength: 0)
                if session.watchlist.refreshing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button {
                        Task { await session.watchlist.refreshAll() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption2)
                            .foregroundStyle(VektorTheme.muted)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Refresh watchlist quotes")
                    .accessibilityLabel("Refresh watchlist quotes")
                }
            }
        } footer: {
            Text("Right-click a tile to remove. Click any tile to analyse that ticker. Quotes auto-refresh on pane open (5-minute freshness window) — manual refresh available top-right.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Error chrome

    @ViewBuilder
    private func errorSection(for err: StocksAnalysisError) -> some View {
        switch err {
        case .coverageGap(let symbol):
            coverageGapCard(symbol: symbol)
        case .invalidKey:
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        StatusBadge(level: .bad)
                        Text("FMP rejected the API key").fontWeight(.medium)
                    }
                    Text("Double-check the key in Settings → Stocks, or paste a fresh one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .generic(let message):
            Section {
                HStack(spacing: 6) {
                    StatusBadge(level: .bad)
                    Text(message).font(.callout)
                }
            }
        }
    }

    /// Calm "not in your plan" result card. Replaces the red HTTP-error
    /// pattern when the failure mode is FMP's catalog gating rather than
    /// a real fault. Explains the cause plainly and offers one quiet
    /// upgrade link — no banners, no modals, no "Upgrade now!" buttons.
    private func coverageGapCard(symbol: String) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    StatusBadge(level: .neutral)
                    Text("\(symbol) isn't in your data plan")
                        .fontWeight(.semibold)
                }
                Text("FMP's free tier focuses on a curated set of major US-listed companies. International listings (Lufthansa, Nestlé, ASML), several US large-caps (BRK.B, MCO, PG, HD, MA), and delisted companies require a paid plan.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Vektor and your key are working — this is a coverage limit, not an error.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    openURL("https://site.financialmodelingprep.com/developer/docs/pricing")
                } label: {
                    Label("See FMP plans", systemImage: "arrow.up.right.square")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(VektorTheme.accent)
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Results

    @ViewBuilder
    private func resultsSections(card: DCAScorecard) -> some View {
        // Hero verdict — the answer to "is this a DCA company?" lives at
        // the top, not buried below six cards. Big total score, the shape
        // one-liner, and the cache-staleness chip if any. Radar drops to
        // the next section so the verdict is the first thing read.
        Section {
            VStack(alignment: .leading, spacing: 12) {
                // Row 1 — symbol + company name + analysis date.
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(card.symbol)
                        .font(.system(.title, design: .monospaced))
                        .foregroundStyle(VektorTheme.accent)
                    Text(card.companyName)
                        .font(.title3)
                        .foregroundStyle(VektorTheme.text)
                        .lineLimit(1)
                    Spacer()
                    Text("analysed \(card.analysedAt.formatted(date: .numeric, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // Row 2 — BIG live price + 1M-change chip, total score on
                // the right (was the headliner; demoted to make room for
                // the price answer to "what's it trading at right now?").
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    if let price = card.currentPrice {
                        Text(formattedPrice(price, currency: card.priceCurrency))
                            .font(.system(size: 36, weight: .semibold, design: .rounded))
                            .foregroundStyle(VektorTheme.text)
                            .monospacedDigit()
                        if let change = card.oneMonthChangePct {
                            ChangeBadge(percent: change)
                                .padding(.bottom, 4)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("\(Int(card.totalScore.rounded()))")
                                .font(.system(size: 28, weight: .semibold, design: .rounded))
                                .foregroundStyle(VektorTheme.accent)
                            Text("/ \(card.maxScore)")
                                .font(.system(.body, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                        Text(card.windowDescription)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                // Row 3 — fair-value verdict + earnings date + securities identifiers.
                HStack(spacing: 8) {
                    if card.fairValueVerdict != .unknown {
                        FairValueBadge(
                            verdict: card.fairValueVerdict,
                            peRatio: card.peRatio,
                            sectorPE: card.sectorPE,
                            sector: card.sector
                        )
                    }
                    if let next = card.nextEarningsAt {
                        EarningsBadge(date: next)
                    }
                    if let wkn = card.wkn {
                        IdentifierChip(label: "WKN", value: wkn)
                    }
                    if let isin = card.isin, !isin.isEmpty {
                        IdentifierChip(label: "ISIN", value: isin)
                    }
                    Spacer()
                }
                Text(card.shape)
                    .font(.callout)
                    .foregroundStyle(VektorTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                if card.stale {
                    HStack(spacing: 6) {
                        StatusBadge(level: .caution)
                        Text("From cache, \(card.cacheAgeDays) day\(card.cacheAgeDays == 1 ? "" : "s") old — API budget exhausted or upstream failed.")
                            .font(.caption)
                    }
                } else if card.fromCache {
                    HStack(spacing: 6) {
                        StatusBadge(level: .neutral)
                        Text("From cache (\(card.cacheAgeDays) day\(card.cacheAgeDays == 1 ? "" : "s") old).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }

        Section {
            VStack(spacing: 6) {
                HStack {
                    Spacer()
                    RadarChart(axes: card.axes)
                    Spacer()
                }
                .padding(.vertical, 8)

                radarBenchmarkLegend
            }
        }

        Section("Scores") {
            ForEach(card.axes) { axis in
                axisRow(axis, card: card)
            }
        }
    }

    private func axisRow(_ axis: AxisScore, card: DCAScorecard) -> some View {
        let isExpanded = session.expandedAxes.contains(axis.axis)
        // Only allow expansion if there's something more to show than
        // the collapsed row already has — i.e. trend data is present.
        let canExpand = axis.trend != nil

        return VStack(alignment: .leading, spacing: 4) {
            // Header — whole row is the toggle target when expansion is
            // available. The chevron carries the affordance signal.
            Button {
                guard canExpand else { return }
                withAnimation(.easeInOut(duration: 0.18)) {
                    if isExpanded { session.expandedAxes.remove(axis.axis) }
                    else          { session.expandedAxes.insert(axis.axis) }
                }
            } label: {
                HStack(alignment: .center) {
                    if canExpand {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 12)
                    }
                    Text(axis.axis.rawValue)
                        .fontWeight(.medium)
                        .foregroundStyle(VektorTheme.text)
                    Spacer()
                    if let s = axis.score {
                        HStack(spacing: 6) {
                            ScoreBar(score: s)
                            Text("\(Int(s.rounded()))/10")
                                .font(.system(.body, design: .monospaced))
                                .frame(width: 44, alignment: .trailing)
                                .foregroundStyle(VektorTheme.text)
                        }
                    } else {
                        Text("N/A")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canExpand)

            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(axis.headline)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(VektorTheme.muted)
                    if !axis.rationale.isEmpty {
                        Text(axis.rationale)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                if let trend = axis.trend {
                    Sparkline(trend: trend, tier: ScoreTier.tier(for: axis.score))
                }
            }

            if isExpanded, canExpand {
                AxisDetailView(
                    axis: axis.axis,
                    slices: [AxisDetailView.Slice(
                        symbol: card.symbol,
                        score: axis,
                        color: VektorTheme.accent
                    )]
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 2)
    }

    private var footerBar: some View {
        // The whole footer is clickable. It already answers the
        // diagnostic question ("is my key working, how much budget left?")
        // — making it the affordance for the action question ("how do I
        // change the key / plan?") collapses a 6-step Settings detour
        // into one click. Hover background hints clickability.
        Button {
            showManage.toggle()
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(monitor.dotColour)
                    .frame(width: 8, height: 8)
                Text(monitor.label)
                Spacer()
                if let b = budget {
                    Text("\(b.callsToday)/\(b.callsLimit) calls today")
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.up")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.vertical, 6)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.thinMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(VektorTheme.divider)
                .frame(height: 0.5)
        }
        .popover(isPresented: $showManage, arrowEdge: .bottom) {
            StocksManageView(fixedWidth: 380)
                .padding(16)
                .themedSheet()
        }
    }

    // MARK: - Analysis

    private func analyse() {
        session.task?.cancel()
        searchTask?.cancel()
        showSuggestions = false
        let symbol = session.ticker.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !symbol.isEmpty else { return }
        // Snap the visible field to the upper-cased symbol so the row
        // header in the result reads the same as what the user sees.
        session.ticker = symbol
        session.rememberLastAnalysed(symbol)
        recordRecent(symbol)
        session.analysisError = nil
        session.loading = true
        session.expandedAxes.removeAll()   // new analysis → start collapsed

        session.task = Task { @MainActor in
            // FMPClient reads the Keychain lazily on its first API call,
            // gated by `KeychainStorage.hasKey(...)` — no eager fetch
            // needed here. We only need to ensure the in-actor cache is
            // populated for runs after a fresh paste, which the manage
            // view + setup card already trigger via
            // `refreshAPIKeyFromKeychain()`.
            do {
                let bundle = try await FMPClient.shared.analyse(symbol: symbol)
                let parsed = try FMPParser.parse(symbol: symbol, bundle: bundle)
                let card = DCAScorer.score(parsed, bundle: bundle)
                if Task.isCancelled { return }
                session.scorecard = card
            } catch {
                if Task.isCancelled { return }
                session.analysisError = classify(error)
                session.scorecard = nil
            }
            session.loading = false
            await refreshBudget()
        }
    }

    private func classify(_ error: Error) -> StocksAnalysisError {
        if let fmp = error as? FMPClient.FMPError {
            switch fmp {
            case .symbolNotCovered(let s):
                return .coverageGap(symbol: s)
            case .invalidAPIKey:
                return .invalidKey
            default:
                return .generic(fmp.errorDescription ?? "\(fmp)")
            }
        }
        if let local = error as? LocalizedError, let msg = local.errorDescription {
            return .generic(msg)
        }
        return .generic(error.localizedDescription)
    }

    private func refreshBudget() async {
        let snap = await FMPClient.shared.budgetSnapshot()
        await MainActor.run { budget = snap }
    }

    private func recordRecent(_ symbol: String) {
        var list = recents.filter { $0 != symbol }
        list.insert(symbol, at: 0)
        if list.count > 6 { list = Array(list.prefix(6)) }
        recentTickersRaw = list.joined(separator: ",")
    }

    private func openURL(_ raw: String) {
        guard let url = URL(string: raw) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Typeahead

    /// Debounced fuzzy search. Triggers only when input has 2+ chars
    /// AND looks like something other than a plain ticker (lowercase,
    /// spaces, or >5 chars) — otherwise it'd fire on every keystroke
    /// of "AAPL" and burn budget for no benefit.
    private func scheduleSearch(query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            searchHits = []
            showSuggestions = false
            return
        }
        let looksLikeTicker = trimmed.count <= 5
            && trimmed == trimmed.uppercased()
            && !trimmed.contains(" ")
        guard !looksLikeTicker else {
            searchHits = []
            showSuggestions = false
            return
        }
        searchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            let hits = (try? await FMPClient.shared.searchSymbols(query: trimmed)) ?? []
            if Task.isCancelled { return }
            searchHits = hits
            showSuggestions = !hits.isEmpty
        }
    }

    private var suggestionsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(searchHits) { hit in
                Button {
                    session.ticker = hit.symbol
                    showSuggestions = false
                    analyse()
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(hit.symbol)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(VektorTheme.accent)
                            .frame(width: 70, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(hit.name)
                                .font(.callout)
                                .foregroundStyle(VektorTheme.text)
                                .lineLimit(1)
                            if let ex = hit.exchange {
                                Text(ex)
                                    .font(.caption2)
                                    .foregroundStyle(VektorTheme.muted)
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(VektorTheme.surface)
            }
        }
    }

    /// Locale-respecting currency formatter for the hero's big price.
    /// Defaults to USD when FMP doesn't return a currency.
    private func formattedPrice(_ value: Double, currency: String?) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.maximumFractionDigits = 2
        f.minimumFractionDigits = 2
        f.currencyCode = (currency?.isEmpty == false) ? currency : "USD"
        f.locale = Locale(identifier: "en_US")
        return f.string(from: NSNumber(value: value)) ?? String(format: "$%.2f", value)
    }
}

/// Visual score bar — ten cells, filled to the score, accent-coloured.
/// Kept private to the Stocks pane; lives next to its only caller.
private struct ScoreBar: View {
    let score: Double
    var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<10, id: \.self) { i in
                Rectangle()
                    .fill(Double(i) < score
                          ? VektorTheme.accent
                          : VektorTheme.divider)
                    .frame(width: 6, height: 10)
            }
        }
        .accessibilityLabel("Score \(Int(score.rounded())) out of ten")
    }
}
