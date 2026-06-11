import SwiftUI
import AppKit
import VektorEngine
import os

struct CalculatorPane: View {
    let engine: NumiEngine?
    let error: String?
    @ObservedObject var documents: DocumentStore
    @Environment(\.openSettings) private var openSettings
    @EnvironmentObject private var calculatorBridge: CalculatorBridge

    @State private var results: [LineResult] = []
    @State private var evaluateTask: Task<Void, Never>? = nil
    @State private var showingCheatsheet: Bool = false
    @State private var showingSheets: Bool = false
    /// Width of the editor column inside the unified scroll surface.
    /// Persisted so the user's preferred split survives launches; the
    /// drag handle in the gutter divider writes back to this value.
    @AppStorage("vektor.calc.editorWidth") private var editorWidth: Double = 460

    /// Drives a periodic re-evaluation so live data (METAR/TAF freshness
    /// labels, current-time timezone results, FX rates) refreshes on its
    /// own without the user having to type. The actual upstream network
    /// fetches are still gated by per-service cooldowns; this just makes
    /// sure those cooldowns get *checked* on a regular cadence.
    private let recomputeTick = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if let error {
                ContentUnavailableView("Engine failed to start",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else {
                VStack(spacing: 0) {
                    sheetHeader
                    UnifiedEditor(
                        text: Binding(
                            get: { documents.selected.content },
                            set: { documents.updateSelectedContent($0) }
                        ),
                        editorWidth: Binding(
                            get: { CGFloat(editorWidth) },
                            set: { editorWidth = Double($0) }
                        ),
                        results: results,
                        renderValue: { Self.renderValue($0) },
                        renderAnnotation: { Self.renderAnnotation($0) },
                        onPageReferenceClicked: { slug in
                            calculatorBridge.jumpToDocument(slug)
                        },
                        resolvePageReference: { slug in
                            documents.findBySlug(slug) != nil
                        }
                    )
                    .overlay(alignment: .bottomLeading) { chromeButtons }
                }
            }
        }
        .background(VektorTheme.background)
        .onChange(of: documents.selectedID) { _, _ in evaluate() }
        .onChange(of: documents.selected.content) { _, _ in scheduleEvaluate() }
        .onAppear { evaluate() }
        .onReceive(NotificationCenter.default.publisher(for: CityResolver.notificationName)) { _ in
            evaluate()
        }
        .onReceive(NotificationCenter.default.publisher(for: MetarCacheBridge.notificationName)) { _ in
            evaluate()
        }
        // Stock quotes ride the same re-eval pattern: bridge fires this
        // notification when a fetched quote (or an error like "not in
        // your data plan") lands, the pane re-evaluates and the gutter
        // updates inline without the user having to type again.
        .onReceive(NotificationCenter.default.publisher(for: QuoteCacheBridge.notificationName)) { _ in
            evaluate()
        }
        // FX or crypto rates just landed in the JSContext — re-evaluate so
        // currency conversions stop showing the offline placeholder.
        // Without this the user sees `100 EUR + 25 USD = 125 USD` (1:1)
        // for the first 60 seconds of every launch, until either the
        // periodic tick fires or they happen to type something.
        .onReceive(NotificationCenter.default.publisher(for: NumiEngine.ratesUpdatedNotification)) { _ in
            evaluate()
        }
        // Every minute, re-evaluate the whole document. This refreshes the
        // freshness label on METAR/TAF lines (and current-time timezone
        // lines), and triggers `handleMetarLine` to nudge the cache bridge
        // — which itself decides whether to actually go to the network.
        .onReceive(recomputeTick) { _ in evaluate() }
        .sheet(isPresented: $showingCheatsheet) {
            CheatsheetView()
        }
    }

    // MARK: - Sheet header

    /// Chrome strip above the editor — `SHEET · <NAME>` in tracked small-caps
    /// with a hairline below. Title is inferred from the document's first
    /// meaningful line (see `VektorDocument.title`); empty docs read as
    /// "SCRATCH". Sans-serif on purpose so the chrome reads as a distinct
    /// layer from the monospaced editor content below.
    private var sheetHeader: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                pinToggleButton

                Button {
                    showingSheets.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Text("SHEET")
                        Text("·")
                        Text(documents.selected.title.uppercased())
                            .lineLimit(1)
                            .truncationMode(.tail)
                        // Subtle chevron earns the header its
                        // "this is interactive" affordance without
                        // adding a separate button. Visible always at
                        // low opacity, opaque on hover via macOS's
                        // default button feedback.
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .opacity(0.6)
                            .padding(.leading, -3)
                    }
                    .font(.system(size: 10.5, weight: .medium))
                    .tracking(1.6)
                    .foregroundStyle(VektorTheme.muted)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Switch sheet")
                .accessibilityLabel("Switch sheet")
                .popover(isPresented: $showingSheets, arrowEdge: .bottom) {
                    SheetsPopover(store: documents,
                                  isPresented: $showingSheets)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)

            Rectangle()
                .fill(VektorTheme.divider)
                .frame(height: 0.5)
        }
        // Invisible shortcut surface: ⌘⇧1 / ⌘⇧2 / ⌘⇧3 jump to the
        // first three pinned sheets in pin-order (most-recently-updated
        // first, matching what the popover shows). Bound in the header
        // because the calculator pane is where you switch sheets;
        // putting it here keeps the binding live for as long as the
        // calculator is on screen.
        .background(pinnedShortcutsLayer)
    }

    /// One-click pin toggle for the currently-displayed sheet. Lives in
    /// the chrome the user is already looking at — the moment they
    /// think "I want to come back to this" the affordance is in their
    /// field of view, not buried behind right-click. Outline icon when
    /// unpinned (muted, low opacity); filled accent when pinned (the
    /// same visual the docs popover uses for state indication).
    private var pinToggleButton: some View {
        let isPinned = documents.selected.isPinned
        return Button {
            documents.togglePinned(documents.selectedID)
        } label: {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(.system(size: 10))
                .foregroundStyle(isPinned ? VektorTheme.accent : VektorTheme.muted)
                .rotationEffect(.degrees(45))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Pinned state is always at full opacity — it's an indicator
        // as much as a button. Unpinned fades so the chrome stays
        // quiet until the user looks for the affordance.
        .opacity(isPinned ? 1.0 : 0.55)
        .help(isPinned ? "Unpin sheet" : "Pin sheet to top")
        .accessibilityLabel(isPinned ? "Unpin sheet" : "Pin sheet to top")
    }

    private var pinnedShortcutsLayer: some View {
        let pinned = documents.documents
            .filter { $0.isPinned }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(3)
        return VStack(spacing: 0) {
            ForEach(Array(pinned.enumerated()), id: \.element.id) { index, doc in
                Button("Switch to pinned sheet \(index + 1)") {
                    documents.select(doc.id)
                }
                .keyboardShortcut(
                    KeyEquivalent(Character("\(index + 1)")),
                    modifiers: [.command, .shift]
                )
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    // MARK: - Gear

    private var chromeButtons: some View {
        HStack(spacing: 0) {
            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .imageScale(.medium)
                    .foregroundStyle(VektorTheme.muted)
                    .padding(8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Preferences (⌘,)")
            .accessibilityLabel("Preferences")

            Button {
                showingCheatsheet = true
            } label: {
                Image(systemName: "questionmark.circle")
                    .imageScale(.medium)
                    .foregroundStyle(VektorTheme.muted)
                    .padding(8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // ⌘? = ⌘+Shift+/ on US keyboards; SwiftUI maps the literal
            // "?" character to that combo. Mirrors the cheatsheet
            // toggle pattern from Numi, Notion, GitHub Desktop.
            .keyboardShortcut("?", modifiers: .command)
            .help("Quick reference (⌘?)")
            .accessibilityLabel("Quick reference")
        }
        .padding(.leading, 6)
        .padding(.bottom, 4)
    }

    // MARK: - Evaluation

    private func scheduleEvaluate() {
        evaluateTask?.cancel()
        evaluateTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            if !Task.isCancelled { evaluate() }
        }
    }

    private func evaluate() {
        guard let engine else { return }
        let newResults = engine.evaluate(documents.selected.content)
        results = newResults
        Self.logIdentityUnitRegressions(in: documents.selected.content, results: newResults)
    }

    // MARK: - Render (LineResult → NSAttributedString)

    /// Main result text, sans the freshness annotation (which renders on
    /// its own line so a long METAR/TAF doesn't bury it).
    /// Numi-style: lines that don't parse render blank. Empty / structural
    /// lines also render blank so the row keeps its baseline.
    static func renderValue(_ r: LineResult) -> NSAttributedString {
        switch r.kind {
        case .error:
            // Errors render blank (Numi-style) — except when the engine
            // attached a hint explaining the failure (a `sum` over a block
            // that mixes united and bare values). The muted reason replaces
            // the silent void so the user knows *why* there's no result.
            let monoFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            guard let hint = r.hint, !hint.isEmpty else {
                let blank = NSMutableAttributedString(string: " ")
                blank.addAttribute(.font, value: monoFont,
                                   range: NSRange(location: 0, length: blank.length))
                return blank
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .right
            paragraph.lineBreakMode = .byWordWrapping
            let attr = NSMutableAttributedString(string: hint)
            let range = NSRange(location: 0, length: attr.length)
            attr.addAttribute(.font, value: monoFont, range: range)
            attr.addAttribute(.paragraphStyle, value: paragraph, range: range)
            attr.addAttribute(.foregroundColor, value: NSColor(VektorTheme.muted), range: range)
            return attr
        default:
            let rawText = display(r)
            let baseColor = NSColor(color(r))
            let isWeather = isWeatherText(rawText)
            // Normalise the aviationweather.gov PROB-on-its-own-line
            // quirk so PROB30/PROB40 reads on the same line as the
            // TEMPO/BECMG it modifies. Only runs on weather text.
            let text = isWeather ? joinProbGroups(rawText) : rawText
            let result = NSMutableAttributedString()
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let monoFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            let paragraph = NSMutableParagraphStyle()
            // Numeric / unit results align to the right column edge so the
            // last digit lines up with every other line (Numi-style). Weather
            // text instead aligns to the *left* of the result column so the
            // first token of every line (METAR ID, FM/BECMG/TEMPO change
            // groups, freshness annotation) flushes to the same x — matching
            // the canonical aviation-weather paper format and keeping
            // PROB30/TEMPO/BECMG groups readable across a wrap.
            paragraph.alignment = isWeather ? .left : .right
            paragraph.lineBreakMode = .byWordWrapping
            for (idx, line) in lines.enumerated() {
                // Freshness sentinel: a zero-width prefix from the
                // briefing handler marking this line as a per-airport
                // METAR/TAF age summary. Strip the sentinel, render
                // with the same styling as `renderAnnotation` (10.5pt
                // mono, tone colour) so multi-airport briefings show
                // a freshness chip under each block.
                if let freshness = freshnessFromSentinel(line) {
                    let cleaned = NSMutableAttributedString(string: freshness.text)
                    let r = NSRange(location: 0, length: cleaned.length)
                    cleaned.addAttribute(
                        .font,
                        value: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular),
                        range: r
                    )
                    cleaned.addAttribute(.paragraphStyle, value: paragraph, range: r)
                    let colour: NSColor
                    switch freshness.tone {
                    case .fresh:    colour = NSColor(VektorTheme.muted)
                    case .stale:    colour = NSColor(VektorTheme.statusCaution)
                    case .outdated: colour = NSColor(VektorTheme.statusBad)
                    }
                    cleaned.addAttribute(.foregroundColor, value: colour, range: r)
                    result.append(cleaned)
                    if idx < lines.count - 1 {
                        result.append(NSAttributedString(string: "\n",
                                                        attributes: [
                                                            .font: monoFont,
                                                            .paragraphStyle: paragraph,
                                                        ]))
                    }
                    continue
                }
                let lineAttr = NSMutableAttributedString(string: line)
                let lineRange = NSRange(location: 0, length: lineAttr.length)
                lineAttr.addAttribute(.font, value: monoFont, range: lineRange)
                lineAttr.addAttribute(.paragraphStyle, value: paragraph, range: lineRange)
                if line.hasPrefix("expect RWY") {
                    lineAttr.addAttribute(.foregroundColor,
                                          value: NSColor(VektorTheme.accent),
                                          range: lineRange)
                } else {
                    lineAttr.addAttribute(.foregroundColor, value: baseColor, range: lineRange)
                }
                // Wind gusts: always safe (regex is very specific).
                applyHighGustHighlight(to: lineAttr, source: line)
                // Vis + ceiling: only for weather text. The 4-digit
                // visibility regex is broad enough that running it on
                // arbitrary calculator output (e.g. "2026" in a date,
                // "4309" in a share count) would produce false-positive
                // red highlights.
                if isWeather {
                    applyVisibilityHighlight(to: lineAttr, source: line)
                    applyCeilingHighlight(to: lineAttr, source: line)
                    applyThunderstormHighlight(to: lineAttr, source: line)
                    applySignificantWeatherHighlight(to: lineAttr, source: line)
                }
                result.append(lineAttr)
                if idx < lines.count - 1 {
                    result.append(NSAttributedString(string: "\n",
                                                    attributes: [
                                                        .font: monoFont,
                                                        .paragraphStyle: paragraph,
                                                    ]))
                }
            }
            // Missing-unit hint ("EUR?" / "no unit") — muted, sitting right
            // where the unit would go. Informational only; the value text
            // is untouched. Hinted values are single-line numerics, so
            // appending after the loop can't land mid-multiline.
            if let hint = r.hint, !hint.isEmpty {
                let h = NSMutableAttributedString(string: " " + hint)
                let range = NSRange(location: 0, length: h.length)
                h.addAttribute(.font, value: monoFont, range: range)
                h.addAttribute(.paragraphStyle, value: paragraph, range: range)
                h.addAttribute(.foregroundColor, value: NSColor(VektorTheme.muted), range: range)
                result.append(h)
            }
            return result
        }
    }

    /// Decode the briefing freshness sentinel from a line. The engine
    /// emits a zero-width prefix (`\u{200B}` / `\u{200C}` / `\u{200D}`)
    /// to mark per-airport METAR/TAF age summaries; the prefix encodes
    /// the tone. Returns nil for ordinary lines.
    static func freshnessFromSentinel(_ line: String) -> (text: String, tone: LineResult.Annotation.Tone)? {
        guard let first = line.unicodeScalars.first else { return nil }
        let tone: LineResult.Annotation.Tone
        switch first.value {
        case 0x200B: tone = .fresh
        case 0x200C: tone = .stale
        case 0x200D: tone = .outdated
        default:     return nil
        }
        let text = String(line.unicodeScalars.dropFirst())
        return (text, tone)
    }

    /// "updated X min ago" / similar freshness annotation, on its own
    /// line beneath the main value. Returns nil when nothing to show.
    static func renderAnnotation(_ r: LineResult) -> NSAttributedString? {
        guard let a = r.annotation else { return nil }
        let attr = NSMutableAttributedString(string: a.label)
        let range = NSRange(location: 0, length: attr.length)
        attr.addAttribute(.font,
                          value: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular),
                          range: range)
        let paragraph = NSMutableParagraphStyle()
        // Mirror the body alignment: weather lines render flush-left
        // inside the result column, so the freshness label sits flush
        // with them. Non-weather annotations keep the right-aligned
        // Numi-style behavior.
        paragraph.alignment = isWeatherText(display(r)) ? .left : .right
        attr.addAttribute(.paragraphStyle, value: paragraph, range: range)
        let colour: NSColor
        switch a.tone {
        case .fresh:    colour = NSColor(VektorTheme.muted)
        case .stale:    colour = NSColor(VektorTheme.statusCaution)
        case .outdated: colour = NSColor(VektorTheme.statusBad)
        }
        attr.addAttribute(.foregroundColor, value: colour, range: range)
        return attr
    }

    /// Tag any `G{value}KT` gust group above 20 kt in the accent
    /// colour. Mirrors the SwiftUI version that lived in this file
    /// before the layout refactor.
    private static let highGustRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"G(\d{2,3})KT\b"#)
    }()
    private static func applyHighGustHighlight(to attr: NSMutableAttributedString, source: String) {
        guard let regex = Self.highGustRegex else { return }
        let ns = source as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        for match in regex.matches(in: source, range: fullRange) {
            let gustRange = match.range(at: 1)
            guard gustRange.location != NSNotFound,
                  let gust = Int(ns.substring(with: gustRange)),
                  gust > 20
            else { continue }
            // attr was built from `source` 1:1, so the same NSRange applies.
            attr.addAttribute(.foregroundColor,
                              value: NSColor(VektorTheme.accent),
                              range: match.range)
        }
    }

    /// METAR/TAF visibility highlight — semantic colouring against the
    /// US flight-category thresholds (boundaries inclusive, matching
    /// the FAA convention where vis ≤ 3 SM is IFR and ≤ 5 SM is MVFR):
    ///   • vis ≤ 5000 m  → red    (IFR territory)
    ///   • vis ≤ 8000 m  → amber  (MVFR territory)
    ///   • otherwise no highlight
    ///
    /// The regex matches any standalone 4-digit token NOT bracketed by
    /// `/` (which excludes TAF validity ranges like `1506/1612` and RVR
    /// values like `R25/1500`). Word boundaries handle altimeter
    /// (`Q1018`/`A2992`) and timestamp (`150550Z`) cases — letters
    /// adjacent to the digits break the `\b` boundary.
    private static let visibilityMetersRegex: NSRegularExpression? = {
        // `(?! ft)` excludes altitude readings ("1516 ft" in briefing /
        // altitude output) which would otherwise be painted red as if
        // they were sub-5000-m visibility values.
        try? NSRegularExpression(pattern: #"(?<!/)\b(\d{4})\b(?! ft)(?!/)"#)
    }()
    /// US-style statute-mile visibility (e.g. `5SM`, `3SM`). Fractional
    /// forms like `1 1/2SM` are deliberately skipped — they're already
    /// low enough to render as red on most marginal METARs via the
    /// integer form when present.
    private static let visibilityStatuteRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"\b(\d+)SM\b"#)
    }()
    private static func applyVisibilityHighlight(to attr: NSMutableAttributedString, source: String) {
        let ns = source as NSString
        let fullRange = NSRange(location: 0, length: ns.length)

        if let regex = visibilityMetersRegex {
            for match in regex.matches(in: source, range: fullRange) {
                let valueRange = match.range(at: 1)
                guard valueRange.location != NSNotFound,
                      let v = Int(ns.substring(with: valueRange))
                else { continue }
                let colour: NSColor
                if v <= 5000      { colour = NSColor(VektorTheme.statusBad) }
                else if v <= 8000 { colour = NSColor(VektorTheme.statusCaution) }
                else              { continue }
                attr.addAttribute(.foregroundColor, value: colour, range: match.range)
            }
        }
        if let regex = visibilityStatuteRegex {
            for match in regex.matches(in: source, range: fullRange) {
                let valueRange = match.range(at: 1)
                guard valueRange.location != NSNotFound,
                      let v = Int(ns.substring(with: valueRange))
                else { continue }
                let colour: NSColor
                if v <= 3      { colour = NSColor(VektorTheme.statusBad) }
                else if v <= 5 { colour = NSColor(VektorTheme.statusCaution) }
                else           { continue }
                attr.addAttribute(.foregroundColor, value: colour, range: match.range)
            }
        }
    }

    /// METAR/TAF ceiling highlight. A ceiling is the lowest `BKN` /
    /// `OVC` / `VV` layer; `FEW` and `SCT` are not ceilings. Each
    /// matching layer is highlighted independently against the FAA
    /// flight-category boundaries (inclusive):
    ///   • height ≤ 1000 ft AGL → red   (IFR / LIFR)
    ///   • height ≤ 3000 ft AGL → amber (MVFR)
    /// Optional `CB` / `TCU` suffix on cloud groups (e.g. `BKN035CB`,
    /// `BKN020TCU`) breaks the simple `\b(\d{3})\b` match because the
    /// digit→letter transition is not a word boundary. Including the
    /// suffix as part of the pattern lets the regex match the full
    /// cloud token; the colour is still applied to the BKN/OVC/VV +
    /// digits portion (`match.range`), and the suffix is coloured
    /// separately by `applySignificantWeatherHighlight`.
    private static let ceilingRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"\b(BKN|OVC|VV)(\d{3})(?:CB|TCU)?\b"#)
    }()
    private static func applyCeilingHighlight(to attr: NSMutableAttributedString, source: String) {
        guard let regex = ceilingRegex else { return }
        let ns = source as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        for match in regex.matches(in: source, range: fullRange) {
            let prefixRange = match.range(at: 1)
            let heightRange = match.range(at: 2)
            guard heightRange.location != NSNotFound,
                  prefixRange.location != NSNotFound,
                  let hundreds = Int(ns.substring(with: heightRange))
            else { continue }
            let feet = hundreds * 100
            let colour: NSColor
            if feet <= 1000      { colour = NSColor(VektorTheme.statusBad) }
            else if feet <= 3000 { colour = NSColor(VektorTheme.statusCaution) }
            else                 { continue }
            // Colour only BKN/OVC/VV + the height digits, NOT the
            // optional CB/TCU suffix — the suffix gets its own colour
            // from `applySignificantWeatherHighlight` (TCU amber, CB
            // red). Without this restriction, the ceiling pass would
            // overwrite the suffix colour.
            let ceilingRange = NSRange(
                location: prefixRange.location,
                length: prefixRange.length + heightRange.length
            )
            attr.addAttribute(.foregroundColor, value: colour, range: ceilingRange)
        }
    }

    /// METAR/TAF thunderstorm highlight — `TS`, `TSRA`, `+TSRA`,
    /// `-TSRA`, `TSGR`, `TSGSRA`, etc. all match. Painted red
    /// regardless of intensity prefix: a thunderstorm is the
    /// hazard (CB clouds, lightning, downdrafts, wind shear) —
    /// the precipitation type is informational, not a tier change.
    ///
    /// The regex captures the whole token including any leading
    /// `+`/`-` intensity character, anchored on whitespace or
    /// line boundaries so we don't false-match `TS` inside other
    /// words (e.g. `MOST` or a remark abbreviation).
    private static let thunderstormRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"(?:^|\s)([+\-]?TS[A-Z]{0,6})(?=\s|$)"#)
    }()
    private static func applyThunderstormHighlight(to attr: NSMutableAttributedString, source: String) {
        guard let regex = thunderstormRegex else { return }
        let ns = source as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        for match in regex.matches(in: source, range: fullRange) {
            // Group 1 is the token without the leading whitespace.
            let tokenRange = match.range(at: 1)
            guard tokenRange.location != NSNotFound else { continue }
            attr.addAttribute(.foregroundColor,
                              value: NSColor(VektorTheme.statusBad),
                              range: tokenRange)
        }
    }

    /// METAR/TAF significant-weather highlights beyond visibility, ceiling,
    /// and TS-prefixed tokens. Two tiers, both anchored so the regexes
    /// can't false-match inside unrelated text.
    ///
    /// **Red (severe — avoid):**
    ///   • `CB` — cumulonimbus cloud (thunderstorm-active)
    ///   • `FZRA`, `FZDZ`, `FZFG` — freezing precipitation / fog (severe icing)
    ///   • `+RA`, `+SN`, `+DZ`, `+TSRA`, `+SHRA`, `+SHSN` — heavy precipitation
    ///   • `GR` — hail
    ///   • `VA` — volcanic ash
    ///   • `DS`, `SS`, `+DS`, `+SS` — duststorm / sandstorm
    ///   • `FC` — funnel cloud / tornado / waterspout
    ///   • `SQ` — squall
    ///
    /// **Amber (caution):**
    ///   • `TCU` — towering cumulus (precursor to CB)
    ///   • `SHRA`, `SHSN`, `SHGR`, `SHGS` — showers (convective, can be turbulent)
    ///   • `GS` — small hail
    ///   • `FG` — fog (visibility hazard)
    ///
    /// Order matters: caution runs first so severe overwrites where
    /// they overlap on the same range (e.g., `+SHRA` should land in
    /// the severe tier, not caution).

    /// Cloud-suffix CB (severe). Word boundaries match it as a suffix
    /// on cloud groups like `BKN035CB` (digit→letter is a boundary).
    private static let cloudSuffixSevereRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"\bCB\b"#)
    }()
    /// Cloud-suffix TCU (caution).
    private static let cloudSuffixCautionRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"\bTCU\b"#)
    }()
    /// Whitespace-anchored severe weather groups. Each group is a
    /// standalone METAR token; `(?:^|\s)…(?=\s|$)` anchors prevent
    /// false matches inside arbitrary identifiers.
    private static let severeWeatherGroupRegex: NSRegularExpression? = {
        let alts = [
            "VA", "GR", "FZRA", "FZDZ", "FZFG", "SQ", "FC", "DS", "SS",
            #"\+RA"#, #"\+SN"#, #"\+DZ"#, #"\+TSRA"#, #"\+SHRA"#, #"\+SHSN"#,
            #"\+DS"#, #"\+SS"#,
        ].joined(separator: "|")
        return try? NSRegularExpression(pattern: "(?:^|\\s)(\(alts))(?=\\s|$)")
    }()
    /// Whitespace-anchored caution weather groups.
    private static let cautionWeatherGroupRegex: NSRegularExpression? = {
        let alts = ["SHRA", "SHSN", "SHGR", "SHGS", "FG", "GS"].joined(separator: "|")
        return try? NSRegularExpression(pattern: "(?:^|\\s)(\(alts))(?=\\s|$)")
    }()

    private static func applySignificantWeatherHighlight(to attr: NSMutableAttributedString,
                                                         source: String) {
        let ns = source as NSString
        let fullRange = NSRange(location: 0, length: ns.length)

        func apply(regex: NSRegularExpression?, captureGroup: Int, color: NSColor) {
            guard let regex else { return }
            for match in regex.matches(in: source, range: fullRange) {
                let r = match.range(at: captureGroup)
                guard r.location != NSNotFound else { continue }
                attr.addAttribute(.foregroundColor, value: color, range: r)
            }
        }

        // Caution first; severe second so any overlap (e.g. `+SHRA`
        // would otherwise be matched as `SHRA` caution + `+SHRA` severe)
        // ends with the severe colour.
        apply(regex: cautionWeatherGroupRegex, captureGroup: 1,
              color: NSColor(VektorTheme.statusCaution))
        apply(regex: cloudSuffixCautionRegex, captureGroup: 0,
              color: NSColor(VektorTheme.statusCaution))
        apply(regex: severeWeatherGroupRegex, captureGroup: 1,
              color: NSColor(VektorTheme.statusBad))
        apply(regex: cloudSuffixSevereRegex, captureGroup: 0,
              color: NSColor(VektorTheme.statusBad))
    }

    /// Join orphan `PROB30` / `PROB40` lines onto the following
    /// `TEMPO` or `BECMG` line. aviationweather.gov's "raw" format
    /// applies whitespace-based line wrapping with no semantic
    /// awareness — `PROB\d\d` is a *modifier* on the next change
    /// group, not a change group itself, but the upstream often
    /// breaks the line between them. Standard ICAO/WMO format keeps
    /// them juxtaposed:
    ///
    ///   PROB30 TEMPO 1513/1517 4000 TSRA SCT020 BKN035CB
    ///
    /// not:
    ///
    ///   PROB30
    ///   TEMPO 1513/1517 4000 TSRA SCT020 BKN035CB
    ///
    /// The regex matches only this exact upstream quirk (PROB +
    /// optional whitespace + newline + indent + TEMPO|BECMG) and
    /// collapses it to a single space. No other reformatting.
    private static let probGroupRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"(PROB\d{2})\s*\n\s*(TEMPO|BECMG)"#)
    }()
    private static func joinProbGroups(_ text: String) -> String {
        guard let regex = probGroupRegex else { return text }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        return regex.stringByReplacingMatches(
            in: text, range: range, withTemplate: "$1 $2"
        )
    }

    /// True when the result text looks like a METAR / TAF / SPECI / ATIS.
    /// We gate the vis + ceiling highlights on this so the 4-digit
    /// visibility regex doesn't accidentally repaint values like
    /// "2026" (year strings) or "4309M" (share counts) in arbitrary
    /// calculator results. Also drives flush-left alignment of the
    /// result column so multi-line weather reports read like the
    /// canonical paper format instead of cascading toward the right.
    private static func isWeatherText(_ s: String) -> Bool {
        s.hasPrefix("METAR ") || s.hasPrefix("TAF ") ||
        s.hasPrefix("SPECI ") || s.hasPrefix("ATIS ")
    }

    private static func display(_ r: LineResult) -> String {
        switch r.kind {
        case .empty, .header, .comment, .label: return " "
        case .expression, .timezone:
            let v = r.value ?? ""
            if v.isEmpty || v == "undefined" || v == "null" { return " " }
            return v
        case .error:
            return r.value ?? ""
        }
    }

    private static func color(_ r: LineResult) -> Color {
        switch r.kind {
        case .error:      return VektorTheme.statusCaution
        case .timezone:   return VektorTheme.accent
        case .expression: return VektorTheme.text
        default:          return VektorTheme.muted
        }
    }

    // MARK: - Diagnostics

    private static let identityLogger = Logger(subsystem: "app.vektor.Vektor", category: "calculator-diag")
    private static let identityConversionRegex: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"^\s*([\d.,]+)\s*([A-Za-z]{3,4})\s+(?:in|to)\s+([A-Za-z]{3,4})\s*$"#
        )
    }()

    private static func logIdentityUnitRegressions(in source: String, results: [LineResult]) {
        guard let regex = identityConversionRegex else { return }
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for r in results where r.kind == .expression {
            guard r.line < lines.count else { continue }
            let raw = lines[r.line]
            let ns = raw as NSString
            guard let m = regex.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)),
                  m.numberOfRanges == 4
            else { continue }
            let srcCur = ns.substring(with: m.range(at: 2)).uppercased()
            let dstCur = ns.substring(with: m.range(at: 3)).uppercased()
            guard srcCur != dstCur else { continue }
            guard let value = r.value else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            guard let unitStart = trimmed.lastIndex(of: " ") else { continue }
            let unit = String(trimmed[trimmed.index(after: unitStart)...]).uppercased()
            if unit == srcCur && unit != dstCur {
                identityLogger.error("identity-conversion regression: \(raw) → \(value) (FX bridge may have failed to register \(dstCur))")
            }
        }
    }
}

// MARK: - AutocompletingTextView (preserved verbatim from prior layout)
//
// The editor's custom NSTextView with ghost-suggestion drawing. The
// surrounding container changed (UnifiedEditor instead of HSplitView)
// but this class itself is unchanged.

final class AutocompletingTextView: NSTextView {

    private var ghostSuggestion: String?
    /// Distinguishes a unit-completion ghost (Tab/Return both accept) from
    /// a blank-line demo hint (Tab accepts; Return falls through to a
    /// regular newline so the user can still add empty lines).
    private var ghostIsHint: Bool = false
    /// Monotonic counter the engine uses to pick which demo to show.
    /// Bumped each time the doc transitions from "has content" to "empty
    /// again" — so opening a fresh tab shows the next demo in the
    /// rotation, but typing then deleting then typing again doesn't
    /// spin the hint wildly.
    private var hintRotation: Int = 0

    /// Closure the editor's enclosing container installs so a click
    /// on an `@reference` token can navigate to another document.
    /// Receives the lowercased slug; no-op when unset.
    var onPageReferenceClicked: ((String) -> Void)?
    /// Returns `true` if a slug resolves to an existing document.
    /// When `false` (or unset), clicking the `@ref` falls through to
    /// default caret placement so the token is still text-editable.
    /// Mirrors the resolver used by the styling pass — same source of
    /// truth, refreshed on every SwiftUI render.
    var resolvePageReference: ((String) -> Bool)?

    func recomputeSuggestion() {
        let cursor = selectedRange().location

        // 1. Unit-completion ghost wins when one is active — that's a
        //    direct response to the user's typing.
        if let completion = SuggestionEngine.suggest(in: string, cursor: cursor) {
            updateGhost(completion, isHint: false)
            return
        }

        // 2. Demo hint: only on a fully-empty doc. Once the user has
        //    typed anything, they've signalled "I know what I want" —
        //    blank lines in the middle of a real doc are now their
        //    workspace, not a discovery surface. The hint reappears if
        //    they wipe the doc clean and start fresh, picking the next
        //    demo in the rotation so they see breadth across sessions.
        if isDocumentEmpty() {
            if !ghostIsHint {
                hintRotation &+= 1
            }
            updateGhost(SuggestionEngine.demoHint(rotation: hintRotation),
                        isHint: true)
            return
        }

        // 3. Nothing to show.
        updateGhost(nil, isHint: false)
    }

    private func updateGhost(_ suggestion: String?, isHint: Bool) {
        if suggestion != ghostSuggestion || isHint != ghostIsHint {
            ghostSuggestion = suggestion
            ghostIsHint = isHint
            needsDisplay = true
        }
    }

    private func isDocumentEmpty() -> Bool {
        string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    override func draw(_ rect: NSRect) {
        super.draw(rect)
        drawGhost()
    }

    /// Intercept clicks landing on `@ref` tokens — those navigate
    /// to the linked document instead of placing the caret. All
    /// other clicks fall through to NSTextView's default handling.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let containerOrigin = textContainerOrigin
        let inContainer = NSPoint(x: point.x - containerOrigin.x,
                                  y: point.y - containerOrigin.y)
        if let layoutManager,
           let textContainer,
           let storage = textStorage {
            let glyphIndex = layoutManager.glyphIndex(for: inContainer,
                                                     in: textContainer)
            let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
            if charIndex < storage.length {
                let slug = storage.attribute(
                    UnifiedCoordinator.pageReferenceAttributeKey,
                    at: charIndex,
                    effectiveRange: nil
                ) as? String
                // Navigate only when the slug actually points somewhere.
                // Unresolved @refs fall through to default caret placement
                // so the user can click into the token to edit it.
                if let slug, !slug.isEmpty, resolvePageReference?(slug) == true {
                    onPageReferenceClicked?(slug)
                    return
                }
            }
        }
        super.mouseDown(with: event)
    }

    private func drawGhost() {
        guard let suggestion = ghostSuggestion, !suggestion.isEmpty,
              let layoutManager, let textContainer
        else { return }

        let nsString = string as NSString
        let cursor = selectedRange().location
        guard cursor >= 0, cursor <= nsString.length else { return }

        let glyphIndex: Int
        if cursor < nsString.length {
            glyphIndex = layoutManager.glyphIndexForCharacter(at: cursor)
        } else {
            glyphIndex = layoutManager.numberOfGlyphs
        }

        let fragment: NSRect
        let pointInFragment: NSPoint

        if glyphIndex < layoutManager.numberOfGlyphs {
            fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            pointInFragment = layoutManager.location(forGlyphAt: glyphIndex)
        } else if layoutManager.numberOfGlyphs > 0 {
            let lastGlyph = layoutManager.numberOfGlyphs - 1
            fragment = layoutManager.lineFragmentRect(forGlyphAt: lastGlyph, effectiveRange: nil)
            let lastLoc = layoutManager.location(forGlyphAt: lastGlyph)
            let lastBox = layoutManager.boundingRect(
                forGlyphRange: NSRange(location: lastGlyph, length: 1),
                in: textContainer
            )
            pointInFragment = NSPoint(x: lastLoc.x + lastBox.width, y: lastLoc.y)
        } else {
            fragment = layoutManager.extraLineFragmentRect
            pointInFragment = NSPoint(x: 0, y: 0)
        }

        let x = fragment.origin.x + pointInFragment.x + textContainerOrigin.x
        let y = fragment.origin.y + textContainerOrigin.y

        // Hints render dimmer than completions so the user can tell at a
        // glance "this is a tip, not the system finishing my word." Same
        // typeface and weight; just lower alpha.
        let ghostAlpha: CGFloat = ghostIsHint ? 0.40 : 0.55
        let chipAlpha: CGFloat = ghostIsHint ? 0.55 : 0.70
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            .foregroundColor: NSColor(VektorTheme.muted).withAlphaComponent(ghostAlpha)
        ]
        (suggestion as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)

        let chipFont = NSFont.monospacedSystemFont(ofSize: 9, weight: .medium)
        let chipAttrs: [NSAttributedString.Key: Any] = [
            .font: chipFont,
            .foregroundColor: NSColor(VektorTheme.muted).withAlphaComponent(chipAlpha)
        ]
        let ghostSize = (suggestion as NSString).size(withAttributes: attrs)
        // Different chip label: ↩ = "press Return to accept this completion",
        // ⇥ try = "press Tab to drop this demo in" — Return on a hint
        // keeps its newline meaning instead.
        let chip = ghostIsHint ? "  ⇥ try" : "  ↩"
        (chip as NSString).draw(
            at: NSPoint(x: x + ghostSize.width, y: y + 2),
            withAttributes: chipAttrs
        )
    }

    override func keyDown(with event: NSEvent) {
        if ghostSuggestion != nil {
            switch event.keyCode {
            case 36:  // Return
                // For demo hints, Return keeps its normal meaning (newline)
                // so the user can still create blank lines without being
                // forced to commit to whatever hint happens to be showing.
                // Tab is the dedicated "accept this hint" key.
                if !ghostIsHint {
                    acceptSuggestion()
                    return
                }
            case 48:  // Tab — always accepts the current ghost
                acceptSuggestion()
                return
            case 53:  // Escape — dismiss
                ghostSuggestion = nil
                ghostIsHint = false
                needsDisplay = true
                return
            default:
                break
            }
        }
        super.keyDown(with: event)
    }

    private func acceptSuggestion() {
        guard let suggestion = ghostSuggestion else { return }
        let cursor = selectedRange().location
        insertText(suggestion, replacementRange: NSRange(location: cursor, length: 0))
        ghostSuggestion = nil
        ghostIsHint = false
        needsDisplay = true
    }
}
