import SwiftUI
import AppKit
import TallyEngine
import os

struct CalculatorPane: View {
    let engine: NumiEngine?
    let error: String?
    @ObservedObject var documents: DocumentStore
    @Environment(\.openSettings) private var openSettings

    @State private var results: [LineResult] = []
    @State private var evaluateTask: Task<Void, Never>? = nil
    /// Width of the editor column inside the unified scroll surface.
    /// Persisted so the user's preferred split survives launches; the
    /// drag handle in the gutter divider writes back to this value.
    @AppStorage("tally.calc.editorWidth") private var editorWidth: Double = 460

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
                    renderAnnotation: { Self.renderAnnotation($0) }
                )
                .overlay(alignment: .bottomLeading) { gearButton }
            }
        }
        .background(TallyTheme.background)
        .onChange(of: documents.selectedID) { _, _ in evaluate() }
        .onChange(of: documents.selected.content) { _, _ in scheduleEvaluate() }
        .onAppear { evaluate() }
        .onReceive(NotificationCenter.default.publisher(for: CityResolver.notificationName)) { _ in
            evaluate()
        }
        .onReceive(NotificationCenter.default.publisher(for: MetarCacheBridge.notificationName)) { _ in
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
    }

    // MARK: - Gear

    private var gearButton: some View {
        Button {
            openSettings()
        } label: {
            Image(systemName: "gearshape")
                .imageScale(.medium)
                .foregroundStyle(TallyTheme.muted)
                .padding(8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 6)
        .padding(.bottom, 4)
        .help("Preferences (⌘,)")
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
            let blank = NSMutableAttributedString(string: " ")
            blank.addAttribute(.font,
                               value: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                               range: NSRange(location: 0, length: blank.length))
            return blank
        default:
            let text = display(r)
            let baseColor = NSColor(color(r))
            let isWeather = isWeatherText(text)
            let result = NSMutableAttributedString()
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let monoFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .right
            paragraph.lineBreakMode = .byWordWrapping
            for (idx, line) in lines.enumerated() {
                let lineAttr = NSMutableAttributedString(string: line)
                let lineRange = NSRange(location: 0, length: lineAttr.length)
                lineAttr.addAttribute(.font, value: monoFont, range: lineRange)
                lineAttr.addAttribute(.paragraphStyle, value: paragraph, range: lineRange)
                if line.hasPrefix("expect RWY") {
                    lineAttr.addAttribute(.foregroundColor,
                                          value: NSColor(TallyTheme.accent),
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
            return result
        }
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
        paragraph.alignment = .right
        attr.addAttribute(.paragraphStyle, value: paragraph, range: range)
        let colour: NSColor
        switch a.tone {
        case .fresh:    colour = NSColor(TallyTheme.muted)
        case .stale:    colour = NSColor(TallyTheme.statusCaution)
        case .outdated: colour = NSColor(TallyTheme.statusBad)
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
                              value: NSColor(TallyTheme.accent),
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
        try? NSRegularExpression(pattern: #"(?<!/)\b(\d{4})\b(?!/)"#)
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
                if v <= 5000      { colour = NSColor(TallyTheme.statusBad) }
                else if v <= 8000 { colour = NSColor(TallyTheme.statusCaution) }
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
                if v <= 3      { colour = NSColor(TallyTheme.statusBad) }
                else if v <= 5 { colour = NSColor(TallyTheme.statusCaution) }
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
    private static let ceilingRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"\b(BKN|OVC|VV)(\d{3})\b"#)
    }()
    private static func applyCeilingHighlight(to attr: NSMutableAttributedString, source: String) {
        guard let regex = ceilingRegex else { return }
        let ns = source as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        for match in regex.matches(in: source, range: fullRange) {
            let heightRange = match.range(at: 2)
            guard heightRange.location != NSNotFound,
                  let hundreds = Int(ns.substring(with: heightRange))
            else { continue }
            let feet = hundreds * 100
            let colour: NSColor
            if feet <= 1000      { colour = NSColor(TallyTheme.statusBad) }
            else if feet <= 3000 { colour = NSColor(TallyTheme.statusCaution) }
            else                 { continue }
            attr.addAttribute(.foregroundColor, value: colour, range: match.range)
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
                              value: NSColor(TallyTheme.statusBad),
                              range: tokenRange)
        }
    }

    /// True when the result text looks like a METAR / TAF / SPECI. We
    /// gate the vis + ceiling highlights on this so the 4-digit
    /// visibility regex doesn't accidentally repaint values like
    /// "2026" (year strings) or "4309M" (share counts) in arbitrary
    /// calculator results.
    private static func isWeatherText(_ s: String) -> Bool {
        s.hasPrefix("METAR ") || s.hasPrefix("TAF ") || s.hasPrefix("SPECI ")
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
        case .error:      return TallyTheme.statusCaution
        case .timezone:   return TallyTheme.accent
        case .expression: return TallyTheme.text
        default:          return TallyTheme.muted
        }
    }

    // MARK: - Diagnostics

    private static let identityLogger = Logger(subsystem: "app.tally.Tally", category: "calculator-diag")
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

    func recomputeSuggestion() {
        let cursor = selectedRange().location
        let suggestion = SuggestionEngine.suggest(in: string, cursor: cursor)
        if suggestion != ghostSuggestion {
            ghostSuggestion = suggestion
            needsDisplay = true
        }
    }

    override func draw(_ rect: NSRect) {
        super.draw(rect)
        drawGhost()
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

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            .foregroundColor: NSColor(TallyTheme.muted).withAlphaComponent(0.55)
        ]
        (suggestion as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)

        let chipFont = NSFont.monospacedSystemFont(ofSize: 9, weight: .medium)
        let chipAttrs: [NSAttributedString.Key: Any] = [
            .font: chipFont,
            .foregroundColor: NSColor(TallyTheme.muted).withAlphaComponent(0.7)
        ]
        let ghostSize = (suggestion as NSString).size(withAttributes: attrs)
        let chip = "  ↩"
        (chip as NSString).draw(
            at: NSPoint(x: x + ghostSize.width, y: y + 2),
            withAttributes: chipAttrs
        )
    }

    override func keyDown(with event: NSEvent) {
        if ghostSuggestion != nil {
            switch event.keyCode {
            case 36, 48:
                acceptSuggestion()
                return
            case 53:
                ghostSuggestion = nil
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
        needsDisplay = true
    }
}
