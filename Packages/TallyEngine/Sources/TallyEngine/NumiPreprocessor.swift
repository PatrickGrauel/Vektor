import Foundation

/// Rewrites Numi-style natural-language input into math.js-compatible
/// expressions. The preprocessor is intentionally line-oriented: each line
/// is transformed in isolation with access to the previous evaluated values
/// (for `prev` / `sum` / `average`).
struct NumiPreprocessor {

    struct Output {
        let rewritten: String
        let isLabelOnly: Bool
    }

    func transform(_ raw: String, previousValues: [String]) -> Output {
        var line = raw

        // Strip trailing `//` line comments so an expression followed
        // by a side note still evaluates. Required: at least one
        // whitespace char before the `//` so URLs (`http://...`) and
        // similar tokens aren't mistakenly eaten. The everything-past-
        // `//` portion is dropped — same convention as C/Swift/JS.
        if let range = line.range(of: #"\s+//"#, options: .regularExpression) {
            line = String(line[line.startIndex..<range.lowerBound])
        }

        // Strip trailing inline "comments" — Numi syntax is `2 + 2 "note"`,
        // i.e. an opening quote that's whitespace-preceded. A bare `"` that
        // follows a digit (like the inches mark in `12'6"`) must NOT be
        // treated as a comment opener.
        if let range = line.range(of: #"\s+""#, options: .regularExpression) {
            line = String(line[line.startIndex..<range.lowerBound])
        }

        // Label support: `Foo: 1 + 1` -> evaluate the RHS; `Foo:` alone -> label only.
        // Be conservative: only treat as a label when the LHS looks like a
        // plain English identifier (letters/spaces, NO digits) and the colon
        // is the only one on the line. This avoids eating time expressions
        // like `3725 seconds in hh:mm:ss` or `2:30 pm Berlin`.
        let colonCount = line.reduce(0) { $0 + ($1 == ":" ? 1 : 0) }
        if colonCount == 1, let colon = line.firstIndex(of: ":") {
            let lhs = line[line.startIndex..<colon]
            let rhs = line[line.index(after: colon)...]
            let lhsTrimmed = lhs.trimmingCharacters(in: .whitespaces)
            let rhsTrimmed = rhs.trimmingCharacters(in: .whitespaces)
            let isLikelyLabel = !lhsTrimmed.isEmpty && lhsTrimmed.allSatisfy {
                $0.isLetter || $0 == " " || $0 == "_" || $0 == "-"
            }
            if isLikelyLabel {
                if rhsTrimmed.isEmpty {
                    return Output(rewritten: "", isLabelOnly: true)
                }
                line = String(rhs)
            }
        }

        var s = line.trimmingCharacters(in: .whitespaces)
        if s.isEmpty {
            return Output(rewritten: "", isLabelOnly: true)
        }

        s = rewriteCommaDecimals(s)
        // Date math runs FIRST: it can replace `days between … and …` with
        // a literal number that subsequent passes treat as a normal value.
        s = rewriteDateMath(s)
        // Finance natural-language runs BEFORE `rewriteScales` so `300k`,
        // `5.5%`, and `30 years` are still in their human-readable forms
        // when we match the loan/compound patterns.
        s = rewriteFinance(s)
        s = rewriteTipAndSplit(s)
        // Feet-inches parsing has to come before `rewriteCurrencySymbols`
        // (which strips `'`/`"` characters it doesn't recognise) and before
        // unit handling.
        let hasFeetInches = containsFeetInchesNotation(s)
        s = rewriteFeetInches(s)
        s = rewriteDrawingScale(s)
        s = rewriteMaterials(s)
        s = rewriteWordOperators(s)
        s = rewriteCurrencySymbols(s)
        // After symbol expansion (`$20` → `20 USD`) but before conversion
        // / scale parsing, normalise alpha currency codes to uppercase so
        // `eur` / `Eur` / `EUR` are all treated as `EUR`.
        s = rewriteCurrencyCase(s)
        s = rewriteScales(s)
        s = rewritePercentages(s)
        s = rewriteTimeUnits(s)
        s = rewriteCalculationInTime(s)
        s = rewriteHmsFormat(s)
        s = rewriteInchAmbiguity(s)
        s = rewriteConversion(s)
        s = rewritePrev(s, previousValues: previousValues)
        s = rewriteAggregates(s, previousValues: previousValues)

        // If the original line used feet-inches notation AND the user
        // didn't ask for a different output unit, wrap the result in
        // `ftin(...)` so it reads as `20'9"` instead of `1.7272 m`.
        // A trailing `to <unit>` (already lower-cased to `to` by the
        // conversion pass) signals explicit unit intent — leave it alone
        // unless that target unit is itself feet/inch.
        if hasFeetInches {
            let trailingConversion = s.range(of: #"\sto\s+([A-Za-z]+)\s*$"#, options: .regularExpression)
            let convertingToOther: Bool = {
                guard let r = trailingConversion else { return false }
                let target = String(s[r]).split(separator: " ").last.map(String.init) ?? ""
                return !["ft", "feet", "foot", "inch", "inches", "in"].contains(target.lowercased())
            }()
            if !convertingToOther {
                s = "ftin(\(s))"
            }
        }

        return Output(rewritten: s, isLabelOnly: false)
    }

    // MARK: - Finance natural language
    //
    // Translates pilot-/non-pilot-friendly phrases into the JS helpers
    // registered in entry.js:
    //
    //   loan 300k at 5.5% for 30 years    → loan(300000, 5.5/100, 30)
    //   mortgage 450k at 6% for 30y       → loan(450000, 6/100, 30)
    //   compound 1000 at 7% for 10 years  → compound(1000, 7/100, 10)
    //   invest 500/month at 6% for 20 y   → compound(0, 6/100, 20, 500)
    //
    // We use `<rate>/100` (not the % token) so mathjs sees a plain number;
    // the JS helpers explicitly accept a plain number for the rate.

    private func rewriteFinance(_ input: String) -> String {
        var s = input

        // The principal accepts numbers with optional `k` / `M` suffix —
        // we expand the suffix here so we don't have to wait for the later
        // `rewriteScales` pass (which uses parens that confuse the regex).
        //
        //   loan 300k at 5.5% for 30 years  → loan(300000, 5.5/100, 30)
        let amount = #"([0-9.]+)\s*([kKmM]?)"#

        // loan / mortgage <P>[k|M] at <R>% for <T> years
        s = replaceMatches(in: s,
                           pattern: #"\b(?:loan|mortgage)\s+"# + amount + #"\s+at\s+([0-9.]+)\s*%\s+for\s+([0-9.]+)\s*(?:y|yr|yrs|year|years)?\b"#) { groups in
            let p = Self.expandSuffix(groups[1], suffix: groups[2])
            return "loan(\(p), \(groups[3])/100, \(groups[4]))"
        }

        // compound / invest <P>[k|M] at <R>% for <T> years + <PMT>/month
        s = replaceMatches(in: s,
                           pattern: #"\b(?:compound|invest)\s+"# + amount + #"\s+at\s+([0-9.]+)\s*%\s+for\s+([0-9.]+)\s*(?:y|yr|yrs|year|years)?\s*\+\s*([0-9.]+)\s*/\s*month\b"#) { groups in
            let p = Self.expandSuffix(groups[1], suffix: groups[2])
            return "compound(\(p), \(groups[3])/100, \(groups[4]), \(groups[5]))"
        }
        // compound / invest <P>[k|M] at <R>% for <T> years  (no contribution)
        s = replaceMatches(in: s,
                           pattern: #"\b(?:compound|invest)\s+"# + amount + #"\s+at\s+([0-9.]+)\s*%\s+for\s+([0-9.]+)\s*(?:y|yr|yrs|year|years)?\b"#) { groups in
            let p = Self.expandSuffix(groups[1], suffix: groups[2])
            return "compound(\(p), \(groups[3])/100, \(groups[4]))"
        }
        // "<PMT>/month at R% for T years" — savings-only (no initial).
        s = s.replacingOccurrences(
            of: #"\b([0-9.]+)\s*/\s*month\s+at\s+([0-9.]+)\s*%\s+for\s+([0-9.]+)\s*(?:y|yr|yrs|year|years)?\b"#,
            with: "compound(0, $2/100, $3, $1)",
            options: .regularExpression
        )
        return s
    }

    private static func expandSuffix(_ number: String, suffix: String) -> String {
        let n = Double(number) ?? 0
        switch suffix.lowercased() {
        case "k": return String(n * 1_000)
        case "m": return String(n * 1_000_000)
        default:  return number
        }
    }

    // MARK: - Tip / split natural language
    //
    //   20% tip on 86.50            → (86.50 * 20 / 100)        [just the tip]
    //   86.50 + 20% tip             → (86.50 + 86.50 * 20 / 100) [total]
    //   145 split 4                 → (145 / 4)                  [per person]
    //   86.50 + 20% tip split 4     → ((86.50 + 86.50*0.20) / 4) [combined]
    //
    // `split N` is implemented as a trailing-divisor: whatever evaluated
    // expression precedes the keyword is wrapped in parens and divided by N.

    private func rewriteTipAndSplit(_ input: String) -> String {
        var s = input

        // "<P>% tip on <X>"  →  "<X> * <P> / 100"   (tip amount only)
        s = s.replacingOccurrences(
            of: #"(\d+(?:\.\d+)?)\s*%\s+tip\s+on\s+(\d+(?:\.\d+)?)"#,
            with: "($2 * $1 / 100)",
            options: .regularExpression
        )

        // "Y%  tip" → strip the literal " tip" so the standard "+ Y%"
        // percentage rewrite later in the pipeline can recognise the form
        // `<bill> + Y%`.
        s = s.replacingOccurrences(
            of: #"(\d+(?:\.\d+)?)\s*%\s+tip\b"#,
            with: "$1%",
            options: .regularExpression
        )

        // Trailing "split N" — wrap LHS in parens, divide.
        // Use a non-greedy LHS anchored at start-of-string or after an
        // opening paren / operator, so it composes with the rest of the
        // pipeline naturally.
        s = s.replacingOccurrences(
            of: #"^(.+?)\s+split\s+(\d+(?:\.\d+)?)\s*$"#,
            with: "(($1) / $2)",
            options: .regularExpression
        )
        return s
    }

    // MARK: - Date math
    //
    //   days between 2024-01-15 and today  → 486
    //   days until 2026-12-25              → 226
    //   age 1990-03-15                     → 35
    //
    // Computed Swift-side and substituted as a literal integer so the
    // result composes with everything else (multiplications, conversions).

    private func rewriteDateMath(_ input: String) -> String {
        var s = input

        // `days between X and Y` — supports an optional trailing
        // ` in <unit>` (weeks / months / years / hours / minutes)
        // so the Welcome page's `days between today and X in weeks`
        // actually evaluates instead of falling through to a
        // mathjs parse error.
        s = replaceMatches(in: s, pattern: #"\bdays\s+between\s+(\S+)\s+and\s+(\S+)(?:\s+in\s+(weeks?|months?|years?|hours?|minutes?))?\b"#) { groups in
            guard let a = Self.parseDateToken(groups[1]),
                  let b = Self.parseDateToken(groups[2]) else { return nil }
            let days = abs(b.timeIntervalSince(a) / 86400)
            let unit = groups[3].lowercased()
            let value: Double
            switch unit {
            case "weeks", "week":     value = days / 7
            case "months", "month":   value = days / 30.4375     // mean-month days
            case "years", "year":     value = days / 365.25
            case "hours", "hour":     value = days * 24
            case "minutes", "minute": value = days * 1440
            default:                  value = days                // raw days
            }
            // 1-decimal precision for non-day units; integer for days.
            return unit.isEmpty
                ? String(Int(round(value)))
                : String(format: "%.1f", value)
        }

        s = replaceMatches(in: s, pattern: #"\bdays\s+(?:until|to)\s+(\S+)\b"#) { groups in
            guard let d = Self.parseDateToken(groups[1]) else { return nil }
            let days = Int(round(d.timeIntervalSince(Date()) / 86400))
            return String(days)
        }

        s = replaceMatches(in: s, pattern: #"\bage\s+(\S+)\b"#) { groups in
            guard let birth = Self.parseDateToken(groups[1]) else { return nil }
            let cal = Calendar(identifier: .gregorian)
            let years = cal.dateComponents([.year], from: birth, to: Date()).year ?? 0
            return String(years)
        }

        return s
    }

    /// Helper: NSRegex-driven replacement that gives the callback access to
    /// the captured groups so we can compute the replacement Swift-side.
    private func replaceMatches(in input: String,
                                pattern: String,
                                replace: ([String]) -> String?) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return input
        }
        let ns = input as NSString
        let matches = re.matches(in: input, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return input }
        var result = input
        // Apply replacements right-to-left so the captured ranges stay valid
        // as the string shrinks.
        for m in matches.reversed() {
            var groups: [String] = []
            for i in 0..<m.numberOfRanges {
                let r = m.range(at: i)
                groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
            guard let replacement = replace(groups) else { continue }
            if let swiftRange = Range(m.range, in: result) {
                result.replaceSubrange(swiftRange, with: replacement)
            }
        }
        return result
    }

    /// Accepts ISO `yyyy-MM-dd` or the keywords today / now / yesterday /
    /// tomorrow. Returns nil for anything else so the caller leaves the
    /// phrase untouched and surfaces a mathjs error.
    private static func parseDateToken(_ raw: String) -> Date? {
        let t = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let now = Date()
        let cal = Calendar(identifier: .gregorian)
        switch t {
        case "today", "now":      return cal.startOfDay(for: now)
        case "yesterday":         return cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now))
        case "tomorrow":          return cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))
        default:                  return isoDateFormatter.date(from: raw)
        }
    }

    private static let isoDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    // MARK: - Feet & inches arithmetic (US architects' bread and butter)
    //
    // Parses `12'6"` and `12'-6"` (the hyphen form is common on US plan
    // sheets) into `(12 ft + 6 inch)`. Plain `12'` (feet only) and `6"`
    // (inches only) also work. `containsFeetInchesNotation` is consulted at
    // the top of `transform` so we know whether to wrap the final result
    // in `ftin(...)` for nice "F'I"" output.

    private func containsFeetInchesNotation(_ input: String) -> Bool {
        return input.range(of: #"\d+\s*['’]"#, options: .regularExpression) != nil
            || input.range(of: #"\d+\s*[\"”]"#, options: .regularExpression) != nil
    }

    private func rewriteFeetInches(_ input: String) -> String {
        var s = input

        // <F>'-<I>"  or  <F>'<I>"  (with optional hyphen between)
        s = replaceMatches(in: s,
                           pattern: #"(\d+(?:\.\d+)?)\s*['’]\s*-?\s*(\d+(?:\.\d+)?)\s*[\"”]"#) { groups in
            return "(\(groups[1]) ft + \(groups[2]) inch)"
        }

        // Standalone <F>'  (feet only, no inches token)
        s = replaceMatches(in: s,
                           pattern: #"(?<![\d.])(\d+(?:\.\d+)?)\s*['’](?!\s*-?\s*\d)"#) { groups in
            return "(\(groups[1]) ft)"
        }

        // Standalone <I>"  (inches only)
        s = replaceMatches(in: s,
                           pattern: #"(?<![\d.])(\d+(?:\.\d+)?)\s*[\"”](?!\w)"#) { groups in
            return "(\(groups[1]) inch)"
        }

        return s
    }

    // MARK: - Drawing scale  (architect's universal one-liner)
    //
    //   4 500 mm at 1:50         →  (4 500 mm) / 50              (real → drawing)
    //   24 mm on drawing 1:100   →  (24 mm) * 100                (drawing → real)
    //   scale 1:200 of 18 m      →  (18 m) / 200                 (alternate form)

    private func rewriteDrawingScale(_ input: String) -> String {
        var s = input

        // Capture the input unit explicitly so we can pin the OUTPUT to the
        // same unit. Otherwise mathjs auto-promotes 2 400 mm to 2.4 m which
        // is technically correct but jarring on a drawing.
        let unit = #"(mm|cm|m|km|inch|in|ft|yd)"#

        // Drawing-to-real: "<num> <unit> on drawing at 1:<N>"
        s = replaceMatches(in: s, pattern: #"([\d.]+)\s*"# + unit + #"\s+(?:on\s+drawing|drawing)\s+(?:at\s+)?1:(\d+)\b"#) { groups in
            return "(\(groups[1]) \(groups[2]) * \(groups[3])) to \(groups[2])"
        }

        // Real-to-drawing: "<num> <unit> at 1:<N>"  (with required `1:` so
        // we don't collide with `loan … at 5.5% …`).
        s = replaceMatches(in: s, pattern: #"([\d.]+)\s*"# + unit + #"\s+at\s+1:(\d+)\b"#) { groups in
            return "(\(groups[1]) \(groups[2]) / \(groups[3])) to \(groups[2])"
        }

        // Alternate prefix form: "scale 1:<N>[,] <num> <unit>"
        s = replaceMatches(in: s, pattern: #"\bscale\s+1:(\d+),?\s+(?:of\s+)?([\d.]+)\s*"# + unit + #"\b"#) { groups in
            return "(\(groups[2]) \(groups[3]) / \(groups[1])) to \(groups[3])"
        }

        return s
    }

    // MARK: - Material take-off
    //
    //   concrete 6 m x 4 m x 0.15 m       → (6 m) * (4 m) * (0.15 m)
    //   paint 30 m² at 8 m²/L              → (30 m²) / (8 m²/L)
    //   tiles for 25 m² at 30 x 30 cm     → ceil((25 m²) / (30 cm * 30 cm))
    //
    // After mathjs evaluates these we get a clean Unit result (m³, L,
    // unitless tile count).

    private func rewriteMaterials(_ input: String) -> String {
        var s = input

        // Concrete: volume = L × W × H. Force m^3 so mathjs doesn't pick a
        // less-architect-friendly unit like deciliters.
        s = s.replacingOccurrences(
            of: #"\bconcrete\s+([\d.]+\s*\w+)\s*[x×]\s*([\d.]+\s*\w+)\s*[x×]\s*([\d.]+\s*\w+)\b"#,
            with: "(($1) * ($2) * ($3)) to m^3",
            options: .regularExpression
        )

        // Paint: coverage division → L
        s = s.replacingOccurrences(
            of: #"\bpaint\s+([\d.]+\s*m\^?2|[\d.]+\s*m²)\s+at\s+([\d.]+\s*m\^?2|[\d.]+\s*m²)\s*/\s*L\b"#,
            with: "(($1) / ($2 / L)) to L",
            options: .regularExpression
        )

        // Tiles: total area divided by tile area, rounded up.
        s = replaceMatches(in: s,
                           pattern: #"\btiles\s+for\s+([\d.]+\s*m\^?2|[\d.]+\s*m²)\s+at\s+([\d.]+)\s*[x×]\s*([\d.]+)\s*(mm|cm|m)\b"#) { groups in
            // groups[1] = area like "25 m²"
            // groups[2] = tile width, groups[3] = tile height, groups[4] = unit
            return "ceil((\(groups[1])) / (\(groups[2]) \(groups[4]) * \(groups[3]) \(groups[4])))"
        }

        return s
    }

    // MARK: - European comma-decimals
    //
    // Pilots, Europeans, and continental docs use "," as the decimal mark.
    // mathjs requires "." Convert `1,8h` → `1.8h`, `2,5 NM` → `2.5 NM`,
    // `-0,75` → `-0.75`. Restricted to 1–2 fractional digits to avoid
    // mangling thousands separators like `1,000` and function-call commas
    // like `min(1, 2)` (the latter has a space after the comma).
    //
    // Skip the rewrite entirely if the line looks like a function call
    // (`identifier(...)`) so we never accidentally rewrite an argument list.

    private func rewriteCommaDecimals(_ input: String) -> String {
        // If line contains `<word>(`, treat commas as argument separators and
        // leave them alone. Worst case: user has to type a dot inside fn calls.
        if input.range(of: #"\b[A-Za-z_][A-Za-z_0-9]*\("#, options: .regularExpression) != nil {
            return input
        }
        return input.replacingOccurrences(
            of: #"(?<![\d])(\d+),(\d{1,2})(?![\d])"#,
            with: "$1.$2",
            options: .regularExpression
        )
    }

    // MARK: - <calc> in time → hms((calc) h)
    //
    // Aviation use-case: `fuel / consumption in time` — the bare arithmetic
    // result is interpreted as hours and rendered as `hh:mm:ss`. Distinct
    // from `rewriteHmsFormat` because the body has no time unit; we attach
    // `h` ourselves so the existing `hms()` JS helper formats it.
    //
    // Guarded by a numeric-only body check so lines like `Munich in time`
    // (or anything containing letters) fall through untouched, leaving the
    // timezone / city paths alone.
    private func rewriteCalculationInTime(_ input: String) -> String {
        let suffix = #"\s+(?:to|in|as)\s+time\s*$"#
        guard let r = input.range(of: suffix, options: .regularExpression) else {
            return input
        }
        let body = input[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
        let allowed = CharacterSet(charactersIn: "0123456789.+-*/()% ")
        let hasDigit = body.contains(where: { $0.isNumber })
        let onlyAllowed = body.unicodeScalars.allSatisfy { allowed.contains($0) }
        guard hasDigit, onlyAllowed else { return input }
        return "hms((\(body)) h)"
    }

    // MARK: - hh:mm:ss / hms output target
    //
    // Numi-style: `1.8h in hh:mm:ss`, `90min as hms`, `3600s in hh:mm`.
    // Rewrite the suffix to a `hms(...)` call which formats the inner value
    // as a clock-style duration (the JS side defines `hms`).
    private func rewriteHmsFormat(_ input: String) -> String {
        // Use `(?:$|\s)` instead of `\b` because `:` is non-word and `\b`
        // boundary semantics around `hh:mm:ss` can be flaky across engines.
        let suffixes: [(String, String)] = [
            // longest first so we don't match the prefix of a longer one
            (#"\s+(?:to|in|as)\s+hh:mm:ss(?:$|\s)"#,                  "hms"),
            (#"\s+(?:to|in|as)\s+hh:mm(?:$|\s)"#,                     "hm"),
            (#"\s+(?:to|in|as)\s+(?:hms|duration|clock)(?:$|\s)"#,    "hms"),
        ]
        for (pattern, fn) in suffixes {
            if let r = input.range(of: pattern, options: .regularExpression) {
                let body = input[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
                return "\(fn)(\(body))"
            }
        }
        return input
    }

    // MARK: - Time-unit normalisation
    //
    // mathjs treats `min` as the built-in `min(...)` function, so a literal
    // like `12 min` doesn't parse as 12 minutes. Rewrite `<digits> min` →
    // `<digits> minutes`. Same for short forms `s`, `h`, `d` that conflict
    // with other math.js identifiers.

    private func rewriteTimeUnits(_ input: String) -> String {
        var s = input
        // FL250 → 250 FL so mathjs sees the unit suffix.
        s = s.replacingOccurrences(
            of: #"\bFL(\d+)\b"#,
            with: "$1 FL",
            options: .regularExpression
        )
        // 12 min  → 12 minutes      (avoid double-rewrite of "minute(s)")
        s = s.replacingOccurrences(
            of: #"(\d)\s*min(?!ute|s)\b"#,
            with: "$1 minutes",
            options: .regularExpression
        )
        // 30 sec  → 30 seconds      (sec/secs only, not "second(s)")
        s = s.replacingOccurrences(
            of: #"(\d)\s*sec(?!ond)s?\b"#,
            with: "$1 seconds",
            options: .regularExpression
        )
        // 2 hr / 2 hrs / 2 hour → 2 hours
        s = s.replacingOccurrences(
            of: #"(\d)\s*(hr|hrs|hour)\b(?!s)"#,
            with: "$1 hours",
            options: .regularExpression
        )
        return s
    }

    // MARK: - Word operators ("times", "plus", "and", "with")

    private func rewriteWordOperators(_ input: String) -> String {
        var s = input
        let pairs: [(String, String)] = [
            (#"\b(plus|and|with)\b"#, " + "),
            (#"\b(minus|subtract|without)\b"#, " - "),
            (#"\b(times|multiplied by|mul)\b"#, " * "),
            (#"\b(divided by|divide by|divide)\b"#, " / "),
            (#"\bmod\b"#, " mod "),
            (#"\bxor\b"#, " xor "),
        ]
        for (pattern, replacement) in pairs {
            s = s.replacingOccurrences(
                of: pattern, with: replacement, options: .regularExpression
            )
        }
        return s
    }

    // MARK: - Currency symbols → ISO codes

    private static let currencyMap: [String: String] = [
        "$": "USD", "€": "EUR", "£": "GBP", "¥": "JPY", "₽": "RUB", "₿": "BTC",
    ]

    /// ISO codes we recognise as currencies. Mirrors the JS allow-list in
    /// `JS/entry.js::knownCurrencyCodes` — keep the two in sync if you add
    /// a new currency to either side.
    static let currencyCodes: Set<String> = [
        "USD", "EUR", "GBP", "JPY", "CHF", "CAD", "AUD", "NZD", "CNY", "HKD", "SGD",
        "INR", "RUB", "BRL", "MXN", "ZAR", "KRW", "SEK", "NOK", "DKK", "PLN",
        "CZK", "HUF", "TRY", "ILS", "AED", "SAR", "IDR", "THB", "MYR", "PHP",
        "VND", "TWD", "NGN", "EGP", "ARS", "CLP", "COP", "PEN", "MAD", "KES",
        "GHS", "UAH", "RON", "BGN", "ISK", "RSD", "BAM", "BHD", "KWD", "OMR",
        "QAR", "PKR", "BDT", "LKR", "NPR", "MMK", "KHR", "LAK", "MOP", "FJD",
        "XPF", "XCD", "CRC", "DOP", "JMD", "TTD", "BBD", "PAB", "GTQ", "BOB",
        "PYG", "UYU", "VES", "HNL", "NIO", "SVC",
        "BTC", "ETH", "SOL", "ADA", "DOGE", "XRP", "DOT", "LTC", "AVAX", "BNB",
        "USDT", "USDC",
    ]

    /// Normalise currency-code case so users can type `eur`, `Eur`, `EUR`
    /// interchangeably. mathjs is case-sensitive on unit names, and while
    /// the JS bridge registers `EUR`/`eur` aliases when a currency is
    /// first introduced, mixed-case forms like `Eur` would never resolve.
    /// We uppercase any 3-letter alpha token that is a known ISO currency
    /// AND appears in a unit position — either right after a number
    /// (`100 eur`) or right after a conversion keyword (`in eur`).
    /// Anything else is left alone so identifiers / variables / regular
    /// 3-letter words don't get clobbered.
    private func rewriteCurrencyCase(_ input: String) -> String {
        var s = input
        // After a number: `(<num>)<ws><token>`.
        s = replaceMatches(
            in: s,
            pattern: #"(\d(?:[\d ,.]*\d)?)(\s+)([A-Za-z]{3,5})\b"#
        ) { groups in
            let token = groups[3]
            let upper = token.uppercased()
            guard Self.currencyCodes.contains(upper) else {
                return groups[1] + groups[2] + token
            }
            return groups[1] + groups[2] + upper
        }
        // After a conversion keyword: `(in|to|as|into)<ws><token>`.
        s = replaceMatches(
            in: s,
            pattern: #"\b(in|to|as|into)(\s+)([A-Za-z]{3,5})\b"#
        ) { groups in
            let token = groups[3]
            let upper = token.uppercased()
            guard Self.currencyCodes.contains(upper) else {
                return groups[1] + groups[2] + token
            }
            return groups[1] + groups[2] + upper
        }
        return s
    }

    private func rewriteCurrencySymbols(_ input: String) -> String {
        var s = input
        for (sym, code) in NumiPreprocessor.currencyMap {
            // "$20" → "20 USD"
            s = s.replacingOccurrences(
                of: "\\\(sym)\\s*(\\d+(?:[.,]\\d+)?)",
                with: "$1 \(code)",
                options: .regularExpression
            )
            // "20$" → "20 USD"
            s = s.replacingOccurrences(
                of: "(\\d+(?:[.,]\\d+)?)\\s*\\\(sym)",
                with: "$1 \(code)",
                options: .regularExpression
            )
        }
        return s
    }

    // MARK: - Scales ("2k", "5M", "3 billion")

    private func rewriteScales(_ input: String) -> String {
        var s = input
        let pairs: [(String, String)] = [
            (#"(\d+(?:\.\d+)?)\s*k\b"#, "($1 * 1000)"),          // lowercase k = thousands
            (#"(\d+(?:\.\d+)?)\s*M\b"#, "($1 * 1000000)"),       // uppercase M = millions
            // B = billions. The `\b` word-boundary requirement is what
            // keeps `1BTC` (crypto) and `100MB`-style tokens from
            // matching — `B` followed by another word character is not
            // a boundary, so only `1B`, `1B EUR`, `1B/s`, `1B.` etc.
            // are rewritten.
            (#"(\d+(?:\.\d+)?)\s*B\b"#, "($1 * 1000000000)"),    // uppercase B = billions
            (#"(\d+(?:\.\d+)?)\s+thousand\b"#, "($1 * 1000)"),
            (#"(\d+(?:\.\d+)?)\s+million\b"#, "($1 * 1000000)"),
            (#"(\d+(?:\.\d+)?)\s+billion\b"#, "($1 * 1000000000)"),
        ]
        for (pattern, replacement) in pairs {
            s = s.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return s
    }

    // MARK: - Percentage syntax

    /// Handles these Numi forms (mapped to math.js):
    ///   `X% of Y`          → `Y * X/100`
    ///   `X% on Y`          → `Y + Y * X/100`
    ///   `X% off Y`         → `Y - Y * X/100`
    ///   `X - Y%`           → `X - X * Y/100`
    ///   `X + Y%`           → `X + X * Y/100`
    private func rewritePercentages(_ input: String) -> String {
        var s = input
        // X% of Y
        s = s.replacingOccurrences(
            of: #"(\d+(?:\.\d+)?)\s*%\s+of\s+(.+)"#,
            with: "(($2) * $1 / 100)",
            options: .regularExpression
        )
        // X% on Y
        s = s.replacingOccurrences(
            of: #"(\d+(?:\.\d+)?)\s*%\s+on\s+(.+)"#,
            with: "(($2) + ($2) * $1 / 100)",
            options: .regularExpression
        )
        // X% off Y
        s = s.replacingOccurrences(
            of: #"(\d+(?:\.\d+)?)\s*%\s+off\s+(.+)"#,
            with: "(($2) - ($2) * $1 / 100)",
            options: .regularExpression
        )
        // X - Y%  and  X + Y%
        //
        // The LHS must bind to the *single operand* immediately before the
        // `-` / `+`, not the whole expression. Otherwise
        //   `2 + 100 - 5%`
        // greedy-rewrites to `((2 + 100) - (2 + 100) * 5 / 100)` ≈ 96.9,
        // when the user obviously means `2 + (100 - 5%) = 97`.
        //
        // Acceptable single operands:
        //   • a parenthesized group              — (50 + 50)
        //   • a number with an optional unit     — 100 USD, 12.5 km
        //   • a bare identifier                  — total, x
        let lhsTerm = #"(\([^()]+\)|\d+(?:\.\d+)?(?:\s+[A-Za-z][A-Za-z0-9_]*)?|[A-Za-z_][A-Za-z0-9_]*)"#

        s = s.replacingOccurrences(
            of: #"(?<![\w.])"# + lhsTerm + #"\s*-\s*(\d+(?:\.\d+)?)\s*%(?!\s*\w)"#,
            with: "(($1) - ($1) * $2 / 100)",
            options: .regularExpression
        )
        s = s.replacingOccurrences(
            of: #"(?<![\w.])"# + lhsTerm + #"\s*\+\s*(\d+(?:\.\d+)?)\s*%(?!\s*\w)"#,
            with: "(($1) + ($1) * $2 / 100)",
            options: .regularExpression
        )
        return s
    }

    // MARK: - Inch / `in` ambiguity
    //
    // math.js treats `in` as BOTH the conversion operator and the inch unit.
    // That makes `1 in in cm` and `3 ft 6 in in cm` (both in the docs) parse
    // incorrectly. Disambiguate by rewriting the inch-as-unit usage to
    // `inch` *before* the conversion pass swaps `in` → `to`.

    private func rewriteInchAmbiguity(_ input: String) -> String {
        var s = input
        // "3 ft 6 in" (US-style plain-text feet/inches) → "(3 ft + 6 inch)".
        // Without this, math.js multiplies the tokens instead of summing.
        s = replaceMatches(in: s,
                           pattern: #"(\d+(?:\.\d+)?)\s+ft\s+(\d+(?:\.\d+)?)\s+in\b"#) { groups in
            return "(\(groups[1]) ft + \(groups[2]) inch)"
        }
        // Standalone "<n> in" followed by a conversion keyword — `in` here
        // is the unit, not the operator. `\b` keeps us off `into`.
        s = replaceMatches(in: s,
                           pattern: #"(\d+(?:\.\d+)?)\s+in\b(?=\s+(?:in|into|as|to)\s)"#) { groups in
            return "\(groups[1]) inch"
        }
        return s
    }

    // MARK: - Conversion ("X in Y", "X to Y", "X as Y" → "X to Y")

    private func rewriteConversion(_ input: String) -> String {
        var s = input
        // math.js's `to` operator has LOWER precedence than `*` / `/` / `+`
        // etc., so `100 EUR in IDR * 2` parses as `100 EUR to (IDR * 2)` and
        // errors out. Before doing the in→to swap, look for conversions
        // followed by an infix operator and wrap the conversion in parens
        // so the math binds the way users expect.
        //
        //   100 EUR in IDR * 2   →   (100 EUR to IDR) * 2
        //   1 m in cm * 2        →   (1 m to cm) * 2
        //
        // The LHS pattern is intentionally narrow: a number with optional
        // unit OR a parenthesized expression. Matching `.+?` against the
        // whole line would over-capture and produce wrong parens.
        let convWord = #"(?:in|into|as|to)"#
        let lhs = #"((?:\([^()]+\)|[\d.]+(?:\s+[A-Za-z][A-Za-z0-9_]*)?))"#
        let unit = #"([A-Za-z]{2,}|°[A-Za-z])"#
        // Require whitespace BEFORE the operator so we don't fire on
        // compound units like `km/h` or `m/s` where `/` is part of the unit
        // expression, not an arithmetic operator.
        s = s.replacingOccurrences(
            of: #"(?<![\w.])"# + lhs + #"\s+"# + convWord + #"\s+"# + unit + #"(\s+[+\-*/])"#,
            with: "($1 to $2)$3",
            options: .regularExpression
        )

        // End-of-line case for SUMS / DIFFS: when the line contains a
        // binary `+` or `-` BEFORE the conversion, the user means the
        // conversion to apply to the whole expression. Without this,
        // `100 EUR + 25 USD in USD` parses as `100 EUR + (25 USD to USD)`
        // (mathjs's `to` is higher-precedence than `+`) — answer is still
        // numerically right but auto-displayed in the leading unit (EUR),
        // which reads as "wrong" to the user.
        //
        //   100 EUR + 25 USD in USD   →   (100 EUR + 25 USD) to USD
        //   50 m - 20 m in cm         →   (50 m - 20 m) to cm
        s = s.replacingOccurrences(
            of: #"^(.+\s[+\-]\s.+?)\s+"# + convWord + #"\s+"# + unit + #"\s*$"#,
            with: "($1) to $2",
            options: .regularExpression
        )

        // math.js uses "to" for unit conversion. Normalize Numi's "in" / "as" / "into".
        // Careful: "in" is also the unit "inches" in math.js, so we only rewrite when
        // followed by a recognised unit/currency keyword.
        s = s.replacingOccurrences(
            of: "\\s+\(convWord)\\s+(\(unit))",
            with: " to $1",
            options: .regularExpression
        )
        // `min` collides with math.js's `min()` function — when used as a
        // conversion target, force the unambiguous unit spelling.
        s = s.replacingOccurrences(
            of: #"\bto\s+min\b"#,
            with: "to minute",
            options: .regularExpression
        )
        return s
    }

    // MARK: - Previous result (`prev`)

    private func rewritePrev(_ input: String, previousValues: [String]) -> String {
        guard input.contains("prev"), let last = previousValues.last else { return input }
        // Formatted values carry thousands-grouping spaces (`1 800 ft`).
        // mathjs would parse those as implicit multiplication (`1 × 800`)
        // — strip the digit-between-digits space before re-injecting.
        let cleaned = Self.stripThousandsSpaces(last)
        return input.replacingOccurrences(
            of: #"\bprev\b"#,
            with: "(\(cleaned))",
            options: .regularExpression
        )
    }

    // MARK: - Aggregates: `sum` / `total` / `average` / `avg`
    //
    // Handles four shapes:
    //
    //   sum                  → sum of previous values, in the LAST value's
    //                          unit (so `100 USD / 200 USD / 300 EUR / sum`
    //                          comes out in EUR — the unit the user just
    //                          typed and is presumably thinking in)
    //   sum to <unit>        → explicit target unit
    //   sum in <unit>        → ditto (in is alias for to)
    //   sum as <unit>        → ditto
    //
    // Same shapes for `total`, `average`, `avg`. Works for any mathjs unit
    // — currencies, lengths, masses, temperatures, etc. — because the
    // result is just `<base-call>` with a trailing `to <unit>` appended.

    private func rewriteAggregates(_ input: String, previousValues: [String]) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        let pattern = #"^(sum|total|average|avg)(?:\s+(?:to|in|as)\s+(\S+))?$"#

        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return input }
        let ns = trimmed as NSString
        guard let m = re.firstMatch(in: trimmed,
                                    range: NSRange(location: 0, length: ns.length))
        else { return input }

        let kind = ns.substring(with: m.range(at: 1)).lowercased()
        let explicitUnit: String? = {
            let r = m.range(at: 2)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }()

        if previousValues.isEmpty { return "0" }

        // Strip thousands-spaces from every value so mathjs doesn't read
        // "1 800 ft" as "1 × 800 ft". Without this the sum quietly went
        // wrong on any result over 999.
        let joined = previousValues
            .map { "(\(Self.stripThousandsSpaces($0)))" }
            .joined(separator: ",")
        let funcName = (kind == "average" || kind == "avg") ? "mean" : "sum"
        let base = "\(funcName)(\(joined))"

        // Prefer the user's explicit "in/to/as <unit>"; otherwise default
        // to the last value's trailing unit so currencies and lengths
        // come out in the unit the user just typed.
        let target = explicitUnit ?? Self.trailingUnit(of: previousValues.last)
        guard let target else { return base }
        return "(\(base)) to \(target)"
    }

    /// Remove space-between-digits used as a thousands separator while
    /// preserving the space between number and unit. Idempotent on values
    /// that don't have a grouped integer.
    static func stripThousandsSpaces(_ value: String) -> String {
        value.replacingOccurrences(
            of: #"(?<=\d) (?=\d)"#,
            with: "",
            options: .regularExpression
        )
    }

    /// Best-effort: the last whitespace-separated token of a formatted
    /// value, if it looks like a unit identifier (letters, optional `^`
    /// or `/` for compound units, optional `²` / `³`). Returns nil for
    /// strings with no unit (e.g. `"600"`, `"01:48:00"`).
    static func trailingUnit(of value: String?) -> String? {
        guard let value else { return nil }
        let tokens = value.split(whereSeparator: { $0 == " " || $0 == "\u{00A0}" })
                          .map(String.init)
        for token in tokens.reversed() {
            // Strip a trailing exponent so "m²" / "cm³" still register.
            let core = token.unicodeScalars.filter { sc in
                CharacterSet.letters.contains(sc)
                    || sc == "/" || sc == "^"
                    || sc == "°" || sc == "²" || sc == "³"
            }
            if core.count == token.unicodeScalars.count, !token.isEmpty,
               // Must contain at least one letter — rejects pure punctuation.
               token.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) {
                return token
            }
        }
        return nil
    }
}
