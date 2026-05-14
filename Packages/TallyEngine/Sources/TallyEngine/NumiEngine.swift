import Foundation
import JavaScriptCore
import TallyAviation
import os

public struct LineResult: Equatable, Sendable {
    public let line: Int
    public let raw: String
    public let value: String?
    public let kind: Kind
    /// Optional secondary annotation (e.g. "updated 12 min ago" for METAR
    /// lines). Rendered alongside the value in smaller, age-aware colour.
    public let annotation: Annotation?

    public enum Kind: String, Sendable {
        case empty
        case header
        case comment
        case label
        case expression
        case timezone
        case error
    }

    public struct Annotation: Equatable, Sendable {
        public enum Tone: Sendable, Equatable {
            /// Dim secondary colour. Report is fresher than the fastest
            /// routine cycle (30 min at busy international stations).
            case fresh
            /// Accent (gold/orange). Older than the 30-min cycle but still
            /// current at hourly-update stations. Treat with caution.
            case stale
            /// Red. Older than even the hourly cycle — outdated everywhere
            /// and unsafe to rely on without a fresh fetch.
            case outdated
        }
        public let label: String
        public let tone: Tone
        public init(label: String, tone: Tone) {
            self.label = label
            self.tone = tone
        }
    }

    public init(line: Int, raw: String, value: String?, kind: Kind, annotation: Annotation? = nil) {
        self.line = line
        self.raw = raw
        self.value = value
        self.kind = kind
        self.annotation = annotation
    }
}

public enum NumiEngineError: Error, CustomStringConvertible {
    case bundleResourceMissing
    case jsContextUnavailable
    case evaluationFailed(String)

    public var description: String {
        switch self {
        case .bundleResourceMissing: return "mathjs.bundle.js missing from module resources"
        case .jsContextUnavailable: return "JSContext could not be created"
        case .evaluationFailed(let msg): return "Evaluation failed: \(msg)"
        }
    }
}

public final class NumiEngine {
    private let context: JSContext
    private let preprocessor = NumiPreprocessor()
    private let timezone = TimezoneBridge()
    private let resolver = CityResolver.shared
    /// Snapshot of every math.js unit name (incl. aliases/plurals/prefixes)
    /// registered at engine init. Used by `parseConversionForm` to reject
    /// "<n> mm in m"-style queries that look like military-time conversions
    /// but are actually unit conversions in disguise.
    private let knownUnitNames: Set<String>

    public init() throws {
        guard let ctx = JSContext() else { throw NumiEngineError.jsContextUnavailable }
        self.context = ctx

        guard let url = Bundle.module.url(forResource: "mathjs.bundle", withExtension: "js") else {
            throw NumiEngineError.bundleResourceMissing
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        context.exceptionHandler = { _, exc in
            if let exc { NSLog("[NumiEngine] JS exception: \(exc)") }
        }
        _ = context.evaluateScript(source)

        AviationBridge.register(on: context)

        // Capture the unit registry after all unit registrations have run.
        let names = context.evaluateScript("Object.keys(math.Unit.UNITS || {})")?.toArray() as? [String]
        self.knownUnitNames = Set((names ?? []).map { $0.lowercased() })
    }

    /// True when the token (case-insensitive) is a math.js unit. Used to
    /// veto the timezone parser when the line is actually a unit query.
    func isKnownUnit(_ token: String) -> Bool {
        knownUnitNames.contains(token.lowercased())
    }

    /// Posted whenever fresh FX or crypto rates land in the JSContext.
    /// Views that re-evaluate documents (calculator gutter) should listen
    /// for this so currency conversions update without the user having
    /// to type anything. Without the post, the calculator would stay
    /// on whatever placeholder rates were in place when it first
    /// evaluated on `.onAppear`.
    public static let ratesUpdatedNotification = Notification.Name("tally.engine.ratesUpdated")

    private static let logger = Logger(subsystem: "app.tally.Tally", category: "engine")

    public func applyFX(_ snapshot: FXService.Snapshot) {
        let applied = FXBridge.apply(snapshot, to: context)
        if applied == 0 && !snapshot.ratesPerUSD.isEmpty {
            Self.logger.error("applyFX: 0 currencies registered from a \(snapshot.ratesPerUSD.count)-rate snapshot — JS bridge broken?")
        } else {
            Self.logger.info("applyFX: \(applied) currencies (base=\(snapshot.base), ts=\(snapshot.timestamp))")
        }
        NotificationCenter.default.post(name: Self.ratesUpdatedNotification, object: nil)
    }

    public func applyCrypto(_ snapshot: CryptoService.Snapshot) {
        let applied = CryptoBridge.apply(snapshot, to: context)
        Self.logger.info("applyCrypto: \(applied) symbols (ts=\(snapshot.timestamp))")
        NotificationCenter.default.post(name: Self.ratesUpdatedNotification, object: nil)
    }

    /// Evaluate a multi-line Numi-style document.
    ///
    /// Must run on the main actor: the METAR/TAF cache bridge is
    /// `@MainActor`-isolated and we use `MainActor.assumeIsolated` to read
    /// from it synchronously. Without this annotation a background-thread
    /// caller would trip that assertion and crash.
    @MainActor
    public func evaluate(_ source: String) -> [LineResult] {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var results: [LineResult] = []
        var previousValues: [String] = []

        // Fresh document = fresh variable scope. Variables declared on earlier
        // lines (`House = 100k EUR`) flow into later lines (`House * 2`).
        _ = context.evaluateScript("tally.resetScope();")

        for (idx, raw) in lines.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                // Blank lines used to clear `previousValues`, which made
                // `prev` after a blank silently break. Preserve scope so
                // users can leave spacing between related calculations.
                results.append(.init(line: idx, raw: raw, value: nil, kind: .empty))
                continue
            }
            if trimmed.hasPrefix("//") {
                results.append(.init(line: idx, raw: raw, value: nil, kind: .comment))
                continue
            }
            if trimmed.hasPrefix("#") {
                results.append(.init(line: idx, raw: raw, value: nil, kind: .header))
                continue
            }

            if let tzResult = handleTimezoneLine(trimmed) {
                results.append(.init(line: idx, raw: raw, value: tzResult, kind: .timezone))
                previousValues.append(tzResult)
                continue
            }

            if let wx = handleMetarLine(trimmed) {
                results.append(.init(line: idx, raw: raw, value: wx.value, kind: .expression,
                                     annotation: wx.annotation))
                continue
            }

            if let runways = Self.handleRunwayLine(trimmed) {
                results.append(.init(line: idx, raw: raw, value: runways, kind: .expression))
                continue
            }

            if let dist = Self.handleDistanceLine(trimmed) {
                results.append(.init(line: idx, raw: raw, value: dist, kind: .expression))
                continue
            }

            if let sun = Self.handleSunLine(trimmed) {
                results.append(.init(line: idx, raw: raw, value: sun, kind: .expression))
                continue
            }

            let prep = preprocessor.transform(raw, previousValues: previousValues)
            if prep.isLabelOnly {
                results.append(.init(line: idx, raw: raw, value: nil, kind: .label))
                continue
            }

            // Ensure any 3-letter currency codes used on this line are
            // registered as units. Real rates (from FXService) win; this is
            // a no-op once a real rate is in place.
            ensureCurrencies(in: prep.rewritten)

            // Escape for embedding inside a single-quoted JS string literal.
            // Backslash and single-quote are obvious; CR / LF / line- and
            // paragraph-separator chars are illegal in JS source (pre-ES2019
            // for U+2028/2029) and cause cryptic "__ERR__" results when
            // pasted from Windows clipboards or PDFs.
            let escaped = prep.rewritten
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'",  with: "\\'")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
                .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
            let precision = max(2, min(14, UserDefaults.standard.object(forKey: "tally.precision") as? Int ?? 14))
            let js = """
            (() => { try {
                const v = tally.evalLine('\(escaped)');
                return tally.format(v, \(precision));
            } catch (e) { return '__ERR__' + e.message; } })()
            """
            let jsValue = context.evaluateScript(js)
            let str = jsValue?.toString() ?? ""
            if str.hasPrefix("__ERR__") {
                let errorRaw = String(str.dropFirst("__ERR__".count))
                let msg = Self.humaniseError(errorRaw)
                results.append(.init(line: idx, raw: raw, value: msg, kind: .error))
            } else {
                results.append(.init(line: idx, raw: raw, value: str, kind: .expression))
                previousValues.append(str)
            }
        }

        return results
    }

    // MARK: - Timezone phrase recognition

    /// Recognise five Numi-style timezone phrases:
    ///   "<TZ> time"
    ///   "Time in <TZ>"
    ///   "now in <TZ>"
    ///   "<HH:mm[ am/pm]> <FROM_TZ> in <TO_TZ>"
    ///   any of the above with a trailing "+ N" / "- N[h|hours]" offset
    private func handleTimezoneLine(_ line: String) -> String? {
        // 1. Split off any trailing "+ N hours" / "- 2h" / "+2" offset.
        let (workingLine, offsetSeconds) = extractTimeOffset(from: line)

        // Conversion form: "X:YY [am|pm] FROM in TO"
        if let conv = parseConversionForm(workingLine) {
            return resolveConversion(time: conv.time, from: conv.from, to: conv.to,
                                     offsetSeconds: offsetSeconds)
        }

        // Bare time-at-zone: "1430 Zulu", "14:30 Berlin", "2:30 pm HKT"
        if let (time, tz) = parseTimeAtZone(workingLine) {
            return resolveTimeAt(time: time, in: tz, offsetSeconds: offsetSeconds)
        }

        let lowered = workingLine.lowercased()
        if lowered.hasSuffix(" time") {
            let id = String(workingLine.dropLast(5))
            return resolveNow(id: id, offsetSeconds: offsetSeconds)
        }
        if lowered.hasPrefix("time in ") {
            let id = String(workingLine.dropFirst("time in ".count))
            return resolveNow(id: id, offsetSeconds: offsetSeconds)
        }
        if lowered.hasPrefix("now in ") {
            let id = String(workingLine.dropFirst("now in ".count))
            return resolveNow(id: id, offsetSeconds: offsetSeconds)
        }
        // Bare "now" (with or without offset) → local time
        if lowered == "now" {
            return formatLocalNow(offsetSeconds: offsetSeconds)
        }
        if isLikelyBareTimezoneQuery(workingLine) {
            return resolveNow(id: workingLine, offsetSeconds: offsetSeconds)
        }
        // Bare offset only: "+ 30min" applied with no anchor falls back to local now.
        if workingLine.isEmpty && offsetSeconds != 0 {
            return formatLocalNow(offsetSeconds: offsetSeconds)
        }
        return nil
    }

    /// Format `Date() + offsetSeconds` in the user's local timezone.
    private func formatLocalNow(offsetSeconds: TimeInterval) -> String {
        let fmt = DateFormatter()
        fmt.timeZone = TimeZone.current
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd HH:mm zzz"
        return fmt.string(from: Date().addingTimeInterval(offsetSeconds))
    }

    /// Strip every trailing `+/- N[h|m|s]?` offset off the end of the line
    /// and accumulate the total. Supports chained additions:
    ///   "now + 2h + 52min"       → ("now",  2*3600 + 52*60)
    ///   "1430 Zulu + 2"          → ("1430 Zulu", 7200)
    ///   "Berlin time - 90 min"   → ("Berlin time", -5400)
    private func extractTimeOffset(from line: String) -> (String, TimeInterval) {
        var working = line.trimmingCharacters(in: .whitespaces)
        var total: TimeInterval = 0
        while true {
            let (stripped, seconds, matched) = extractOneOffset(from: working)
            if !matched { break }
            total += seconds
            working = stripped
        }
        return (working, total)
    }

    private func extractOneOffset(from line: String) -> (String, TimeInterval, Bool) {
        let regex = #"^(.+?)\s*([+\-])\s*(\d+(?:\.\d+)?)\s*(h|hr|hrs|hour|hours|m|min|mins|minute|minutes|s|sec|secs|second|seconds)?$"#
        let pattern = try? NSRegularExpression(pattern: regex)
        let ns = line as NSString
        guard let result = pattern?.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
              result.numberOfRanges >= 4 else { return (line, 0, false) }

        func group(_ i: Int) -> String? {
            guard i < result.numberOfRanges else { return nil }
            let r = result.range(at: i)
            guard r.location != NSNotFound else { return nil }
            return ns.substring(with: r)
        }

        guard let stripped = group(1),
              let sign = group(2),
              let valueStr = group(3),
              let value = Double(valueStr) else { return (line, 0, false) }
        let unit = group(4) ?? "h"
        let perUnit: TimeInterval
        switch unit.lowercased() {
        case "h", "hr", "hrs", "hour", "hours":       perUnit = 3600
        case "m", "min", "mins", "minute", "minutes": perUnit = 60
        case "s", "sec", "secs", "second", "seconds": perUnit = 1
        default: perUnit = 3600
        }
        let signedValue = (sign == "-") ? -value : value
        return (stripped.trimmingCharacters(in: .whitespaces), signedValue * perUnit, true)
    }

    private struct Conversion { let time: String; let from: String; let to: String }

    /// Match "<time> <timezone>" with no conversion target. Returns the time
    /// and the timezone token. The time can be HH:mm, HHmm, or h:mm a.
    private func parseTimeAtZone(_ line: String) -> (time: String, tz: String)? {
        let regex = #"^(\d{1,2}(?::\d{2})?(?:\s?[AaPp][Mm])?|\d{4})\s+(.+)$"#
        guard line.range(of: regex, options: .regularExpression) != nil else { return nil }
        let pieces = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let first = pieces.first else { return nil }
        // Validate as a time token
        let hasColon = first.contains(":")
        let hasAMPM = first.range(of: #"[AaPp][Mm]"#, options: .regularExpression) != nil
        let isMilitary = first.count == 4 && first.allSatisfy(\.isNumber)
        if !(hasColon || hasAMPM || isMilitary) { return nil }
        if isMilitary,
           let hh = Int(first.prefix(2)),
           let mm = Int(first.suffix(2)),
           hh > 23 || mm > 59 { return nil }
        // For "2:30 pm HKT" the time spans 2 tokens (2:30 + pm). Detect that.
        var timeEnd = 1
        if pieces.count >= 3 {
            let second = pieces[1]
            if second.range(of: #"^[AaPp][Mm]$"#, options: .regularExpression) != nil {
                timeEnd = 2
            }
        }
        let timeStr = pieces.prefix(timeEnd).joined(separator: " ")
        let tzStr = pieces.dropFirst(timeEnd).joined(separator: " ")
        // Only succeed if the TZ resolves — otherwise let the line fall through.
        guard !tzStr.isEmpty,
              (CityResolver.shared.cached(for: tzStr) != nil
               || TimezoneBridge().legacyResolveLocal(tzStr) != nil)
        else { return nil }
        return (timeStr, tzStr)
    }

    private func parseConversionForm(_ line: String) -> Conversion? {
        // Accept either "HH:mm[ am/pm]" or 4-digit military like "1430".
        let regex = #"^(\d{1,4}(?::\d{2})?(?:\s?[AaPp][Mm])?)\s+(.+?)\s+in\s+(.+)$"#
        guard let _ = line.range(of: regex, options: .regularExpression) else { return nil }
        let pieces = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let firstWord = pieces.first else { return nil }
        // Quick veto: if either side of "in" is a registered math.js unit
        // (e.g. "1000 mm in m" or "60 rpm in Hz"), this is a unit conversion
        // disguised as 4-digit-military-time. Let math.js handle it.
        if let lastBeforeIn = pieces.firstIndex(of: "in").map({ pieces[$0 - 1] }),
           let firstAfterIn = pieces.firstIndex(of: "in").map({ pieces[$0 + 1] }) {
            if isKnownUnit(lastBeforeIn) || isKnownUnit(firstAfterIn) {
                return nil
            }
        }
        let firstChunk = pieces.prefix(2).joined(separator: " ")
        let hasColon = firstChunk.contains(":")
        let hasAMPM = firstChunk.range(of: #"[AaPp][Mm]"#, options: .regularExpression) != nil
        // 4-digit military: "1430". Avoid matching things like "100" (3 digits
        // which could mean a temperature/scalar) or "1" (single digit).
        let isMilitary = firstWord.count == 4 && firstWord.allSatisfy(\.isNumber)
        if !hasColon && !hasAMPM && !isMilitary { return nil }
        // Sanity-check that a 4-digit military token is a valid HHmm value.
        if isMilitary,
           let hh = Int(firstWord.prefix(2)),
           let mm = Int(firstWord.suffix(2)),
           hh > 23 || mm > 59 {
            return nil
        }
        guard let inIdx = pieces.firstIndex(of: "in"), inIdx >= 2 else { return nil }

        // Walk back from the "in" token: identify which trailing tokens before
        // "in" form a known timezone/city. Take the longest match.
        let preTokens = Array(pieces[..<inIdx])
        var timeTokens: [String] = []
        var fromTokens: [String] = preTokens
        for splitAt in 1..<preTokens.count {
            let candidateFrom = Array(preTokens[splitAt...])
            let candidateName = candidateFrom.joined(separator: " ")
            if TimezoneBridge().resolveSync(candidateName) != nil
                || CityResolver.shared.cached(for: candidateName) != nil {
                timeTokens = Array(preTokens[..<splitAt])
                fromTokens = candidateFrom
                break
            }
        }
        if timeTokens.isEmpty {
            // Fallback: assume the last token before "in" is the source TZ.
            timeTokens = Array(preTokens.dropLast())
            fromTokens = [preTokens.last ?? ""]
        }
        let toTokens = Array(pieces[(inIdx + 1)...])
        return Conversion(
            time: timeTokens.joined(separator: " "),
            from: fromTokens.joined(separator: " "),
            to:   toTokens.joined(separator: " ")
        )
    }

    private func isLikelyBareTimezoneQuery(_ line: String) -> Bool {
        let words = line.split(separator: " ")
        guard (1...4).contains(words.count) else { return false }
        if line.rangeOfCharacter(from: .decimalDigits) != nil { return false }
        if line.rangeOfCharacter(from: CharacterSet(charactersIn: "+-*/=")) != nil { return false }
        return CityResolver.shared.cached(for: line) != nil
            || TimezoneBridge().legacyResolveLocal(line) != nil
    }

    // MARK: - Resolution helpers (sync, with async kick-off on miss)

    private func resolveNow(id raw: String, offsetSeconds: TimeInterval = 0) -> String? {
        if let out = timezone.nowString(in: raw, offsetSeconds: offsetSeconds) { return decorate(out) }
        kickOffResolve(raw)
        return "Resolving \(raw.trimmingCharacters(in: .whitespaces))…"
    }

    /// Format `time` in `zone`'s timezone, applying any offset, returning a
    /// short "HH:mm zzz  (canonical)" string.
    private func resolveTimeAt(time: String, in zone: String,
                               offsetSeconds: TimeInterval = 0) -> String? {
        if let out = timezone.convertTimeString(time, from: zone, to: zone,
                                                offsetSeconds: offsetSeconds) {
            return decorate(out)
        }
        kickOffResolve(zone)
        return "Resolving \(zone)…"
    }

    private func resolveConversion(time: String, from: String, to: String,
                                   offsetSeconds: TimeInterval = 0) -> String? {
        if let out = timezone.convertTimeString(time, from: from, to: to,
                                                offsetSeconds: offsetSeconds) {
            return decorate(out)
        }
        kickOffResolve(from)
        kickOffResolve(to)
        let need = [from, to]
            .filter { CityResolver.shared.cached(for: $0) == nil && TimezoneBridge().legacyResolveLocal($0) == nil }
            .joined(separator: ", ")
        return "Resolving \(need)…"
    }

    private func decorate(_ out: TimezoneBridge.Output) -> String {
        if let canonical = out.canonical {
            return "\(out.formatted)  (\(canonical))"
        }
        return out.formatted
    }

    // MARK: - METAR / TAF lines in calculator

    /// Detect `METAR XXXX` or `TAF XXXX` lines. Returns the raw weather
    /// report plus a freshness annotation. On a cache miss, kicks off a
    /// fetch + returns a "Fetching…" placeholder.
    private struct MetarLine {
        let value: String
        let annotation: LineResult.Annotation?
    }

    private func handleMetarLine(_ line: String) -> MetarLine? {
        // Single or space-separated multiple ICAOs:
        //   METAR EDMA
        //   METAR EDMA EDMO EDDM
        //   TAF KSFO KLAX KJFK
        //   ATIS KSFO KORD
        // 3- or 4-letter codes (4-letter ICAO; 3-letter IATA resolved later
        // by MetarCacheBridge.cached via AirportCodeMap).
        let pattern = #"^(METAR|TAF|ATIS)\s+([A-Z]{3,4}(?:\s+[A-Z]{3,4})*)$"#
        guard line.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil else {
            return nil
        }
        let tokens = line.split(separator: " ", omittingEmptySubsequences: true).map { String($0).uppercased() }
        guard tokens.count >= 2 else { return nil }
        let kindToken = tokens[0]
        let icaos = Array(tokens.dropFirst())
        let kind: MetarService.ReportKind
        switch kindToken {
        case "TAF":  kind = .taf
        case "ATIS": kind = .atis
        default:     kind = .metar
        }
        let bridge = MetarCacheBridge.shared

        // Walk each ICAO. For each: nudge the bridge (it dedupes via a
        // 5-min cooldown so spam is harmless), pull whatever's currently
        // cached, and accumulate the displayable section.
        var sections: [String] = []
        var tones: [LineResult.Annotation.Tone] = []
        var ages: [Int] = []
        var pendingCount = 0

        for icao in icaos {
            MainActor.assumeIsolated { bridge.prefetch(kind: kind, icao: icao) }
            if let cached = MainActor.assumeIsolated({ bridge.cached(kind: kind, icao: icao) }) {
                sections.append(cached.raw)
                // For METARs only (not TAF/ATIS), see if we can offer a
                // wind-based runway suggestion. Appended as a second
                // visual row right under the raw report. Format:
                //   expect RWY 26L · Hw 4 · Xc 0
                //   expect RWY 26L · Hw 15 (G25) · Xc 3 (G5)
                if kind == .metar, let advice = Self.runwayWindAdvice(forICAO: icao, metarRaw: cached.raw) {
                    sections.append(Self.formatRunwayAdvice(advice))
                }
                // Pilots care about the *observation* / *issue* time (the
                // Zulu stamp in the report), not when we happened to fetch
                // it locally. Fall back to fetch time if the stamp is
                // missing.
                let referenceTime = Self.observationTime(in: cached.raw) ?? cached.fetchedAt
                let age = Int(Date().timeIntervalSince(referenceTime))
                ages.append(age)
                tones.append(Self.freshnessTone(for: cached.raw, kind: kind, ageSeconds: age))
            } else {
                sections.append("Fetching \(kindToken) \(icao)…")
                pendingCount += 1
            }
        }

        let value = sections.joined(separator: "\n")

        // Single-station: keep the existing annotation shape — "updated X min ago".
        if icaos.count == 1 {
            if let age = ages.first, let tone = tones.first {
                let annotation = LineResult.Annotation(
                    label: "updated \(Self.formatAge(age))",
                    tone: tone
                )
                return MetarLine(value: value, annotation: annotation)
            }
            // Single-station cache miss falls through to nil annotation.
            return MetarLine(value: value, annotation: nil)
        }

        // Multi-station: one annotation describing the BATCH. The colour
        // is driven by the worst tone across all stations so the pilot
        // sees "this is stale somewhere" at a glance.
        let worstTone: LineResult.Annotation.Tone =
            tones.contains(.outdated) ? .outdated :
            tones.contains(.stale)    ? .stale    : .fresh
        let label: String
        if ages.isEmpty {
            label = "fetching \(icaos.count) stations…"
        } else if pendingCount > 0 {
            label = "\(pendingCount)/\(icaos.count) pending · oldest \(Self.formatAge(ages.max() ?? 0))"
        } else {
            label = "\(icaos.count) stations · oldest \(Self.formatAge(ages.max() ?? 0))"
        }
        return MetarLine(value: value, annotation: LineResult.Annotation(label: label, tone: worstTone))
    }

    // MARK: - Runway lookup

    /// Recognise `RWY EDMA` / `RUNWAY EDMA` / `RUNWAYS EDDM EDMA …`
    /// lines and return a formatted multi-line runway listing for each
    /// station from the bundled OurAirports database. Magnetic
    /// designators (from the runway *names*) plus true headings are
    /// shown alongside length × width and surface.
    ///
    /// Returns `nil` if the line doesn't match the runway pattern.
    static func handleRunwayLine(_ line: String) -> String? {
        // Match the same multi-ICAO shape as METAR/TAF.
        let pattern = #"^(RWY|RWYS|RUNWAY|RUNWAYS)\s+([A-Z]{3,4}(?:\s+[A-Z]{3,4})*)$"#
        guard line.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil else {
            return nil
        }
        let tokens = line.split(separator: " ", omittingEmptySubsequences: true).map { String($0).uppercased() }
        guard tokens.count >= 2 else { return nil }
        let icaos = Array(tokens.dropFirst())
        let db = RunwayDatabase.shared

        var sections: [String] = []
        for icao in icaos {
            // Canonicalise 3-letter IATA to ICAO so RWY JFK works.
            let canonical = AirportCodeMap.canonicalICAO(from: icao) ?? icao
            let runways = db.runways(forICAO: canonical)
            if runways.isEmpty {
                sections.append("\(canonical): no runway data")
                continue
            }
            // Header line: airport code + count
            sections.append("\(canonical) — \(runways.count) runway\(runways.count == 1 ? "" : "s")")
            for r in runways {
                sections.append("  " + Self.formatRunway(r))
            }
        }
        return sections.joined(separator: "\n")
    }

    /// Look up runways for the airport, parse the METAR's wind group,
    /// and return the best runway-end suggestion. Returns nil if the
    /// airport has no runway data, the METAR has no parseable wind,
    /// or the wind is too light to prefer any runway.
    private static func runwayWindAdvice(forICAO icao: String, metarRaw: String) -> RunwayWindAdvisor.Advice? {
        let canonical = AirportCodeMap.canonicalICAO(from: icao) ?? icao
        let runways = RunwayDatabase.shared.runways(forICAO: canonical)
        guard !runways.isEmpty else { return nil }
        let decoded = MetarParser.parse(metarRaw)
        return RunwayWindAdvisor.advise(metar: decoded, runways: runways)
    }

    /// Render an `Advice` as the user-facing "expect RWY …" line.
    /// Single-line, dot-separated, with gust components in parens.
    /// `Hw` = headwind, `Xw` = crosswind, `Tw` = tailwind — the `w`
    /// suffix means "wind" so the three are visually parallel.
    static func formatRunwayAdvice(_ a: RunwayWindAdvisor.Advice) -> String {
        let head: String
        if a.isTailwind {
            // Headwind component is negative — call it tailwind so the
            // pilot sees the right sign.
            let tw = abs(a.headwindKt)
            if let hg = a.headwindGustKt {
                head = "Tw \(tw) (G\(abs(hg)))"
            } else {
                head = "Tw \(tw)"
            }
        } else {
            if let hg = a.headwindGustKt {
                head = "Hw \(a.headwindKt) (G\(hg))"
            } else {
                head = "Hw \(a.headwindKt)"
            }
        }
        let cross: String
        if let xg = a.crosswindGustKt {
            cross = "Xw \(a.crosswindKt) (G\(xg))"
        } else {
            cross = "Xw \(a.crosswindKt)"
        }
        return "expect RWY \(a.designator) · \(head) · \(cross)"
    }

    // MARK: - Sun events

    /// Recognise `sun EDDM` and return SR / SS / civil-twilight-end
    /// for today at that airport. Returns nil if the line doesn't match.
    ///
    /// Multi-ICAO is supported: `sun EDDM EDMA EDMO` returns one line
    /// per airport so the pilot can compare daylight windows along a
    /// route.
    static func handleSunLine(_ line: String) -> String? {
        let pattern = #"^sun\s+([A-Z]{3,4}(?:\s+[A-Z]{3,4})*)$"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              re.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
        else { return nil }
        let tokens = line.split(separator: " ", omittingEmptySubsequences: true).map { String($0).uppercased() }
        let icaos = Array(tokens.dropFirst())
        guard !icaos.isEmpty else { return nil }

        // Local timezone for displaying alongside Zulu. Tally doesn't
        // resolve the airport's local timezone from coordinates (that
        // would need a tzlite dataset) — instead we use the device's
        // local timezone for the "local" column. Pilots planning at
        // home for a flight to a far station will see the wrong
        // local; document this rather than fudge it.
        let localTZ = TimeZone.current
        let zuluFmt = DateFormatter()
        zuluFmt.dateFormat = "HHmm'Z'"
        zuluFmt.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0) ?? .current
        zuluFmt.locale = Locale(identifier: "en_US_POSIX")
        let localFmt = DateFormatter()
        localFmt.dateFormat = "HH:mm"
        localFmt.timeZone = localTZ
        localFmt.locale = Locale(identifier: "en_US_POSIX")

        let db = RunwayDatabase.shared
        var lines: [String] = []
        for icao in icaos {
            let canon = AirportCodeMap.canonicalICAO(from: icao) ?? icao
            guard let c = db.coordinate(forICAO: canon) else {
                lines.append("\(canon): no coordinates")
                continue
            }
            let ev = SolarEvents.events(latitude: c.latitude, longitude: c.longitude)
            let sr = formatPair(ev.sunrise, zuluFmt, localFmt)
            let ss = formatPair(ev.sunset, zuluFmt, localFmt)
            let ce = formatPair(ev.civilTwilightEnd, zuluFmt, localFmt)
            // Prefix with the ICAO when multiple are requested so the
            // user can tell them apart.
            let prefix = icaos.count > 1 ? "\(canon)  " : ""
            lines.append("\(prefix)SR \(sr) · SS \(ss) · CT-end \(ce)")
        }
        return lines.joined(separator: "\n")
    }

    private static func formatPair(_ date: Date?,
                                   _ zuluFmt: DateFormatter,
                                   _ localFmt: DateFormatter) -> String {
        guard let date else { return "—" }
        return "\(zuluFmt.string(from: date)) (\(localFmt.string(from: date)))"
    }

    // MARK: - Distance + bearing

    /// Recognise `distance EDDM to EDMA` (also `dist`, also `→` arrow,
    /// and an optional `in km|mi|nm` suffix) and return a formatted
    /// great-circle distance plus initial true bearing. Returns nil if
    /// the line doesn't match.
    ///
    /// Default unit is NM (aviation standard). The line carries the
    /// bearing too so the pilot can dial it into a heading bug.
    static func handleDistanceLine(_ line: String) -> String? {
        let pattern = #"^(?:distance|dist)\s+([A-Z]{3,4})\s+(?:to|→)\s+([A-Z]{3,4})(?:\s+in\s+([A-Za-z]+))?$"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length))
        else { return nil }
        let ns = line as NSString
        let from = ns.substring(with: m.range(at: 1)).uppercased()
        let to   = ns.substring(with: m.range(at: 2)).uppercased()
        let unitToken: String? = {
            let r = m.range(at: 3)
            return r.location == NSNotFound ? nil : ns.substring(with: r).lowercased()
        }()

        let canonFrom = AirportCodeMap.canonicalICAO(from: from) ?? from
        let canonTo   = AirportCodeMap.canonicalICAO(from: to)   ?? to
        let db = RunwayDatabase.shared
        guard let a = db.coordinate(forICAO: canonFrom) else {
            return "no coordinates for \(canonFrom)"
        }
        guard let b = db.coordinate(forICAO: canonTo) else {
            return "no coordinates for \(canonTo)"
        }
        let bearing = GreatCircle.initialBearingTrue(
            lat1: a.latitude, lon1: a.longitude,
            lat2: b.latitude, lon2: b.longitude
        )
        let distanceFormatted: String
        switch unitToken {
        case "km":
            let km = GreatCircle.distanceKM(lat1: a.latitude, lon1: a.longitude,
                                            lat2: b.latitude, lon2: b.longitude)
            distanceFormatted = String(format: "%.0f km", km)
        case "mi", "mile", "miles":
            let mi = GreatCircle.distanceMiles(lat1: a.latitude, lon1: a.longitude,
                                               lat2: b.latitude, lon2: b.longitude)
            distanceFormatted = String(format: "%.0f mi", mi)
        case nil, "nm", "nmi", "nauticalmiles":
            let nm = GreatCircle.distanceNM(lat1: a.latitude, lon1: a.longitude,
                                            lat2: b.latitude, lon2: b.longitude)
            distanceFormatted = String(format: "%.0f NM", nm)
        default:
            // Unknown unit — fall back to NM and tag the unit token so
            // the user notices.
            let nm = GreatCircle.distanceNM(lat1: a.latitude, lon1: a.longitude,
                                            lat2: b.latitude, lon2: b.longitude)
            distanceFormatted = String(format: "%.0f NM (unknown unit '\(unitToken ?? "")')", nm)
        }
        return String(format: "%@ · brg %03.0f° T", distanceFormatted, bearing)
    }

    private static func formatRunway(_ r: RunwayInfo) -> String {
        let pair = "\(r.leIdent)/\(r.heIdent)"
        let dims: String = {
            if let m = r.lengthMeters, let w = r.widthMeters {
                return "\(m)×\(w) m"
            } else if let m = r.lengthMeters {
                return "\(m) m"
            }
            return "—"
        }()
        let headings = String(format: "%03.0f°/%03.0f° T", r.leHeadingTrue, r.heHeadingTrue)
        let surface = (r.surface?.isEmpty == false) ? r.surface! : "—"
        let suffix: String
        if r.closed {
            suffix = "  (closed)"
        } else if !r.lighted {
            suffix = "  (unlit)"
        } else {
            suffix = ""
        }
        return "\(pair)  \(dims)  \(surface)  \(headings)\(suffix)"
    }

    private static func formatAge(_ seconds: Int) -> String {
        // Negative age = clock skew or report scheduled for the future
        // (rare TAF case). Clamp to "just now" rather than show a negative.
        let s = max(0, seconds)
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60) min ago" }
        let hours = s / 3600
        let mins = (s % 3600) / 60
        if mins == 0 { return "\(hours) h ago" }
        return "\(hours) h \(mins) min ago"
    }

    /// Translate a raw math.js / engine error message into something a
    /// human can act on. The mathjs strings ("Undefined symbol foo",
    /// "Parenthesis ) expected (char 9)") are parser-internal; users
    /// shouldn't see them unmodified in the gutter.
    public static func humaniseError(_ message: String) -> String {
        let m = message.trimmingCharacters(in: .whitespacesAndNewlines)

        // Undefined symbol / unit  → "Unknown unit 'foo'"
        if let r = m.range(of: #"^Undefined symbol (\S+)"#, options: .regularExpression) {
            let symbol = String(m[r]).replacingOccurrences(of: "Undefined symbol ", with: "")
            return "Unknown unit or name '\(symbol)' — check spelling."
        }
        if let r = m.range(of: #"^Unit (\S+) does not exist"#, options: .regularExpression) {
            let unit = String(m[r])
                .replacingOccurrences(of: "Unit ", with: "")
                .replacingOccurrences(of: " does not exist", with: "")
            return "Unknown unit '\(unit)' — check spelling."
        }

        // Parser shape complaints
        if m.contains("Parenthesis ) expected") {
            return "Missing closing parenthesis."
        }
        if m.contains("Value expected") || m.contains("Unexpected end of expression") {
            return "Expression looks incomplete."
        }
        if m.hasPrefix("Cannot convert") && m.contains("unit") {
            return "Can't convert between those units — dimensions don't match."
        }
        if m.contains("Division by zero") {
            return "Division by zero."
        }
        if m.contains("Wrong number of arguments") {
            return "That function got the wrong number of arguments."
        }

        // Fall through: trim mathjs-internal "(char N)" position suffix
        // so the gutter doesn't leak parser internals.
        return m.replacingOccurrences(of: #"\s*\(char \d+\)"#,
                                      with: "",
                                      options: .regularExpression)
    }

    /// Tone thresholds reflect the actual issuance cadence of each report
    /// kind. Without these, a freshly-issued 24-hour TAF would already
    /// look "stale" after an hour even though pilots haven't seen a new
    /// one published yet.
    ///
    /// METARs / SPECIs / ATIS:
    ///   • International airports: ~30 min cadence
    ///   • FAA airports:           ~60 min cadence
    ///   • SPECI updates anytime conditions change significantly
    ///   → fresh ≤ 35 min, stale 35–70 min, outdated > 70 min
    ///
    /// TAFs are governed by ICAO Annex 3:
    ///   • Validity < 12h:   issued every 3 h  (short TAFs)
    ///   • Validity 12–30h:  issued every 6 h  (standard TAFs)
    ///   → fresh ≤ issue interval + 30 min, stale up to 2× interval,
    ///     outdated beyond that.
    static func freshnessTone(for raw: String,
                              kind: MetarService.ReportKind,
                              ageSeconds age: Int) -> LineResult.Annotation.Tone {
        switch kind {
        case .taf:
            // Standard TAF is 24 h validity → issued every 6 h.
            let validityHours = tafValidityHours(in: raw) ?? 24
            let issueIntervalSec = validityHours < 12 ? 3 * 3600 : 6 * 3600
            let freshLimit   = issueIntervalSec + 30 * 60   // +30 min slack
            let staleLimit   = issueIntervalSec * 2
            if age < freshLimit { return .fresh }
            if age < staleLimit { return .stale }
            return .outdated
        case .metar, .atis:
            if age < 35 * 60 { return .fresh }
            if age < 70 * 60 { return .stale }
            return .outdated
        }
    }

    /// Parse the validity period of a TAF (`DDHH/DDHH`) and return its
    /// duration in hours. Returns nil if no validity group is present.
    static func tafValidityHours(in raw: String) -> Int? {
        let pattern = #"\b(\d{2})(\d{2})/(\d{2})(\d{2})\b"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = raw as NSString
        guard let m = re.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges == 5
        else { return nil }
        let startDay  = Int(ns.substring(with: m.range(at: 1))) ?? 0
        let startHour = Int(ns.substring(with: m.range(at: 2))) ?? 0
        let endDay    = Int(ns.substring(with: m.range(at: 3))) ?? 0
        let endHour   = Int(ns.substring(with: m.range(at: 4))) ?? 0
        // Validate. ICAO allows endHour == 24 to mean "end of day".
        guard (1...31).contains(startDay), (1...31).contains(endDay),
              (0...23).contains(startHour), (0...24).contains(endHour)
        else { return nil }
        let startTotal = startDay * 24 + startHour
        var endTotal   = endDay * 24 + endHour
        // Crude month-rollover handling: if the end falls before the start
        // (different month), shift it forward by ~one month.
        if endTotal <= startTotal { endTotal += 31 * 24 }
        return endTotal - startTotal
    }

    /// Compute the next expected issuance time for a report, given the
    /// raw text of the most recent observation/forecast. Used by the
    /// background refresh job to schedule a re-fetch ~30 s after the
    /// upstream publisher is expected to push the next report — much
    /// tighter than blind 5-min polling and easier on the upstream API.
    ///
    /// METAR: standard issuance is at HH:50–HH:55 each hour. We pick :55
    /// + 30 s as the conservative default. If the cached observation
    /// time is unknown, fall back to "now + 30 min."
    ///
    /// ATIS: variable, ~hourly. Schedule one hour after the cached
    /// observation time + 30 s.
    ///
    /// TAF: depends on validity per ICAO Annex 3. < 12 h validity →
    /// every 3 h. ≥ 12 h validity → every 6 h. Issuance times line up
    /// with UTC clock (00 / 06 / 12 / 18 for 6 h cadence; 00 / 03 / …
    /// for 3 h cadence). We compute the next slot strictly after `after`
    /// and add the 30 s propagation buffer.
    ///
    /// Always returns a date strictly in the future relative to the
    /// `after` argument. The returned cadence is *expected*, not
    /// guaranteed — upstream sometimes runs late, so consumers should
    /// also keep a periodic backstop fetch.
    public static func nextExpectedIssuance(
        for kind: MetarService.ReportKind,
        rawCached: String?,
        after: Date = Date()
    ) -> Date {
        let propagationBuffer: TimeInterval = 30
        let calendar: Calendar = {
            var c = Calendar(identifier: .gregorian)
            c.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0) ?? .current
            return c
        }()

        switch kind {
        case .metar:
            // Next :55 strictly after `after`.
            var comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: after)
            let currentMinute = comps.minute ?? 0
            if currentMinute < 55 {
                comps.minute = 55
            } else {
                // Already past :55 this hour — advance to next hour.
                comps.minute = 55
                if let bumped = calendar.date(byAdding: .hour, value: 1, to: calendar.date(from: comps) ?? after) {
                    comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: bumped)
                    comps.minute = 55
                }
            }
            comps.second = 0
            let base = calendar.date(from: comps) ?? after.addingTimeInterval(60)
            return base.addingTimeInterval(propagationBuffer)

        case .atis:
            // ATIS letters tick roughly hourly with no fixed slot. Use
            // observation time + 60 min if available, else `after + 60 min`.
            let anchor: Date
            if let raw = rawCached, let obs = observationTime(in: raw) {
                anchor = obs.addingTimeInterval(60 * 60)
            } else {
                anchor = after.addingTimeInterval(60 * 60)
            }
            // Don't return a time in the past (e.g. cached obs is very
            // old) — clamp to at least 30 s in the future.
            return max(anchor, after.addingTimeInterval(30)).addingTimeInterval(propagationBuffer)

        case .taf:
            let validityHours = (rawCached.flatMap { tafValidityHours(in: $0) }) ?? 24
            let cadenceHours = validityHours < 12 ? 3 : 6
            // Next UTC slot strictly after `after`.
            var comps = calendar.dateComponents([.year, .month, .day, .hour], from: after)
            let currentHour = comps.hour ?? 0
            let nextSlot = ((currentHour / cadenceHours) + 1) * cadenceHours
            comps.minute = 0
            comps.second = 0
            if nextSlot >= 24 {
                // Rolls into the next UTC day.
                comps.hour = nextSlot - 24
                if let bumped = calendar.date(byAdding: .day, value: 1, to: calendar.date(from: comps) ?? after) {
                    return bumped.addingTimeInterval(propagationBuffer)
                }
            } else {
                comps.hour = nextSlot
            }
            let base = calendar.date(from: comps) ?? after.addingTimeInterval(TimeInterval(cadenceHours) * 3600)
            return base.addingTimeInterval(propagationBuffer)
        }
    }

    /// Extract the first `DDHHmmZ` Zulu timestamp from a METAR / TAF and
    /// resolve it to a `Date` in UTC. If the day-of-month is in the future
    /// relative to today, assume the report rolled over from last month.
    static func observationTime(in raw: String) -> Date? {
        let pattern = #"\b(\d{2})(\d{2})(\d{2})Z\b"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = raw as NSString
        guard let m = re.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length))
        else { return nil }
        guard let day = Int(ns.substring(with: m.range(at: 1))),
              let hour = Int(ns.substring(with: m.range(at: 2))),
              let minute = Int(ns.substring(with: m.range(at: 3))),
              (1...31).contains(day), (0...23).contains(hour), (0...59).contains(minute)
        else { return nil }

        var cal = Calendar(identifier: .gregorian)
        // Defensive: TimeZone(identifier: "UTC") effectively never returns
        // nil, but fall back to GMT-0 rather than force-unwrap on a hot
        // safety-relevant path.
        cal.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0) ?? .current
        let now = Date()
        var comps = cal.dateComponents([.year, .month, .day], from: now)
        let today = comps.day ?? day
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        // If the stamp's day is later than today's UTC day, the report is
        // from the previous month. Subtract one month, wrapping at year.
        if day > today {
            if let mo = comps.month, mo > 1 {
                comps.month = mo - 1
            } else {
                comps.month = 12
                comps.year = (comps.year ?? 0) - 1
            }
        }
        return cal.date(from: comps)
    }

    // MARK: - Lazy currency registration

    /// Extract any 3- or 4-letter uppercase tokens and ask the JS side to
    /// register a placeholder rate if none is loaded yet. `tally.ensureCurrency`
    /// filters against an ISO 4217 allow-list so we don't accidentally turn
    /// every random uppercase identifier into a currency.
    private func ensureCurrencies(in line: String) {
        let pattern = try? NSRegularExpression(pattern: #"\b[A-Z]{3,4}\b"#)
        let ns = line as NSString
        guard let matches = pattern?.matches(
            in: line, range: NSRange(location: 0, length: ns.length)
        ) else { return }

        var seen = Set<String>()
        for m in matches {
            let code = ns.substring(with: m.range)
            if seen.insert(code).inserted {
                _ = context.evaluateScript("tally.ensureCurrency('\(code)');")
            }
        }
    }

    private func kickOffResolve(_ query: String) {
        guard CityResolver.shared.cached(for: query) == nil else { return }
        Task.detached {
            _ = await CityResolver.shared.resolve(query: query)
        }
    }
}
