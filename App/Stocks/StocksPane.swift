import SwiftUI
import AppKit

/// Stocks pane — analyse a public company against Warren Buffett's
/// "Durable Competitive Advantage" framework. Pulls five years of
/// financials from financialmodelingprep.com, scores six axes 0–10, and
/// renders both a textual scorecard and a radar chart.
struct StocksPane: View {
    @AppStorage("tally.stocks.lastTicker") private var lastTicker: String = ""
    @AppStorage("tally.stocks.recentTickers") private var recentTickersRaw: String = ""
    @AppStorage("tally.stocks.fmpApiKey") private var apiKey: String = ""
    // Observe the plan + custom-cap settings so the footer's daily-cap
    // number reflects the user's current plan in real time. Without
    // this, changing the plan in the manage popover refreshes that
    // view's local budget snapshot but leaves the pane's footer state
    // showing the old (free-tier) cap.
    @AppStorage(FMPPlan.storageKey) private var planRaw: String = FMPPlan.free.rawValue
    @AppStorage(FMPPlan.customCapKey) private var customCap: Int = 240
    @StateObject private var monitor = StocksConnectionMonitor.shared

    @State private var ticker: String = ""
    @State private var loading = false
    @State private var analysisError: AnalysisError?
    @State private var scorecard: DCAScorecard?
    @State private var budget: FMPClient.BudgetSnapshot?
    @State private var task: Task<Void, Never>?
    /// Manage popover — the in-pane shortcut to the key / plan / usage
    /// view, anchored to the footer status bar.
    @State private var showManage = false
    /// Which axis rows are expanded into their drill-down view. Backed
    /// by `Axis` directly so toggling survives any re-renders that
    /// reorder the cards.
    @State private var expandedAxes: Set<Axis> = []

    /// Result-side error classification. Each case maps to a different
    /// UI shape: coverage-gap gets the calm "not in your plan" card,
    /// invalid-key bounces the user to the setup card, the rest render
    /// as the small error chrome.
    private enum AnalysisError: Equatable {
        case coverageGap(symbol: String)
        case invalidKey
        case generic(String)
    }

    private var recents: [String] {
        recentTickersRaw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        Form {
            if apiKey.isEmpty {
                // First-run / not-yet-keyed flow — the pane owns its
                // setup so the user doesn't have to spelunk Settings to
                // discover what FMP is or why a Mac app wants a key.
                setupCardSection
            } else {
                inputSection

                if let err = analysisError {
                    errorSection(for: err)
                }

                if loading {
                    Section {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Pulling financials from FMP…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let card = scorecard {
                    resultsSections(card: card)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(TallyTheme.background)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            footerBar
        }
        .onAppear {
            // Restore the last ticker without auto-analysing — analysis
            // is user-driven and budget-consuming.
            if ticker.isEmpty, !lastTicker.isEmpty {
                ticker = lastTicker
            }
            Task { await refreshBudget() }
        }
        .onChange(of: apiKey) { _, new in
            monitor.reflectKeyChange(newKey: new)
            Task { await FMPClient.shared.setAPIKey(new.isEmpty ? nil : new) }
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
        .onDisappear { task?.cancel() }
    }

    // MARK: - Setup card

    /// Setup state shown when no key is set. Explains what FMP is, why
    /// Tally needs a key, and offers a one-click link to get one — all
    /// inline so the user never has to leave the pane to enable it.
    @State private var pastedKey: String = ""

    private var setupCardSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(TallyTheme.accent)
                    Text("Connect a data source")
                        .font(.headline)
                }
                Text("Tally pulls financial statements from **Financial Modeling Prep**, a third-party data provider. You'll need a free account — their free plan covers around 50 analyses per day of major US-listed companies.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button {
                        openURL("https://site.financialmodelingprep.com/developer/docs")
                    } label: {
                        Label("Get a free key", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(TallyTheme.accent)
                    SecureField("Paste your FMP key here", text: $pastedKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 220)
                    Button("Connect") {
                        let trimmed = pastedKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        apiKey = trimmed
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
            Text("Your key stays on this Mac. Tally never sends it anywhere except to FMP. You can change or remove it later in Settings → Stocks.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Input + recents

    private var inputSection: some View {
        Section {
            LabeledContent("Ticker") {
                HStack(spacing: 8) {
                    TextField("", text: $ticker, prompt: Text("KO"))
                        .textCase(.uppercase)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                        .labelsHidden()
                        .onChange(of: ticker) { _, new in
                            let upper = new.uppercased()
                            if upper != new { ticker = upper }
                        }
                        .onSubmit { analyse() }
                    Button("Analyze") { analyse() }
                        .keyboardShortcut(.return, modifiers: [])
                        .disabled(ticker.trimmingCharacters(in: .whitespaces).isEmpty || loading)
                }
            }
            if !recents.isEmpty {
                LabeledContent("Recent") {
                    HStack(spacing: 6) {
                        ForEach(recents, id: \.self) { t in
                            Button(t) {
                                ticker = t
                                analyse()
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(TallyTheme.codeSurface)
                            .clipShape(Capsule())
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(TallyTheme.text)
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

    // MARK: - Error chrome

    @ViewBuilder
    private func errorSection(for err: AnalysisError) -> some View {
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
                Text("Tally and your key are working — this is a coverage limit, not an error.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    openURL("https://site.financialmodelingprep.com/developer/docs/pricing")
                } label: {
                    Label("See FMP plans", systemImage: "arrow.up.right.square")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(TallyTheme.accent)
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
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(card.symbol)
                        .font(.system(.title, design: .monospaced))
                        .foregroundStyle(TallyTheme.accent)
                    Text(card.companyName)
                        .font(.title3)
                        .foregroundStyle(TallyTheme.text)
                    Spacer()
                    Text("analysed \(card.analysedAt.formatted(date: .numeric, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("\(Int(card.totalScore.rounded()))")
                        .font(.system(size: 44, weight: .semibold, design: .rounded))
                        .foregroundStyle(TallyTheme.accent)
                    Text("/ \(card.maxScore)")
                        .font(.system(.title3, design: .rounded))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(card.windowDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(card.shape)
                    .font(.callout)
                    .foregroundStyle(TallyTheme.text)
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
            HStack {
                Spacer()
                RadarChart(axes: card.axes)
                Spacer()
            }
            .padding(.vertical, 8)
        }

        Section("Scores") {
            ForEach(card.axes) { axis in
                axisRow(axis, card: card)
            }
        }
    }

    private func axisRow(_ axis: AxisScore, card: DCAScorecard) -> some View {
        let isExpanded = expandedAxes.contains(axis.axis)
        // Only allow expansion if there's something more to show than
        // the collapsed row already has — i.e. trend data is present.
        let canExpand = axis.trend != nil

        return VStack(alignment: .leading, spacing: 4) {
            // Header — whole row is the toggle target when expansion is
            // available. The chevron carries the affordance signal.
            Button {
                guard canExpand else { return }
                withAnimation(.easeInOut(duration: 0.18)) {
                    if isExpanded { expandedAxes.remove(axis.axis) }
                    else          { expandedAxes.insert(axis.axis) }
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
                        .foregroundStyle(TallyTheme.text)
                    Spacer()
                    if let s = axis.score {
                        HStack(spacing: 6) {
                            ScoreBar(score: s)
                            Text("\(Int(s.rounded()))/10")
                                .font(.system(.body, design: .monospaced))
                                .frame(width: 44, alignment: .trailing)
                                .foregroundStyle(TallyTheme.text)
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
                        .foregroundStyle(TallyTheme.muted)
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
                        color: TallyTheme.accent
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
                .fill(TallyTheme.divider)
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
        task?.cancel()
        let symbol = ticker.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !symbol.isEmpty else { return }
        lastTicker = symbol
        recordRecent(symbol)
        analysisError = nil
        loading = true
        expandedAxes.removeAll()   // new analysis → start collapsed

        task = Task { @MainActor in
            await FMPClient.shared.setAPIKey(apiKey.isEmpty ? nil : apiKey)
            do {
                let bundle = try await FMPClient.shared.analyse(symbol: symbol)
                let parsed = try FMPParser.parse(symbol: symbol, bundle: bundle)
                let card = DCAScorer.score(parsed, bundle: bundle)
                if Task.isCancelled { return }
                scorecard = card
            } catch {
                if Task.isCancelled { return }
                analysisError = classify(error)
                scorecard = nil
            }
            loading = false
            await refreshBudget()
        }
    }

    private func classify(_ error: Error) -> AnalysisError {
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
                          ? TallyTheme.accent
                          : TallyTheme.divider)
                    .frame(width: 6, height: 10)
            }
        }
        .accessibilityLabel("Score \(Int(score.rounded())) out of ten")
    }
}
