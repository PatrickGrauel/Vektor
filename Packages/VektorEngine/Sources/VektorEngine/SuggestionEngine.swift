import Foundation

/// Inline-completion brain for unit conversions.
///
/// Given the current document text and cursor position, returns the *suffix*
/// the editor should render as ghost text. The suggestion is dimension-aware:
/// `10 kg in p…` only proposes mass units (pounds, ounces, …), never a unit
/// from a different dimension like Celsius or hertz.
public enum SuggestionEngine {

    /// Returns the text to display *after* the cursor. `nil` if nothing to
    /// suggest (no conversion underway, no matching candidate, or the user
    /// has already finished a unit name).
    public static func suggest(in text: String, cursor: Int) -> String? {
        let ns = text as NSString
        guard cursor >= 0, cursor <= ns.length else { return nil }
        let currentLine = ns.lineRange(for: NSRange(location: cursor, length: 0))
        let tail = ns.substring(with: NSRange(location: cursor, length: NSMaxRange(currentLine) - cursor))
        guard tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let head = ns.substring(with: NSRange(location: 0, length: cursor))

        // Restrict the regex to the current line.
        let lineRange = (head as NSString).lineRange(for: NSRange(location: (head as NSString).length, length: 0))
        let line = (head as NSString).substring(with: lineRange)

        // Pattern: "<number> <sourceUnit> <conversion> <partialTarget>"
        // sourceUnit and target accept letters, slashes (for km/h), digits
        // (m^2-style), and underscores. The boundary prevents matching the
        // minutes inside a clock such as `11:30pm` or an identifier's tail.
        let lineNS = line as NSString
        guard let m = conversionRegex.firstMatch(in: line, range: NSRange(location: 0, length: lineNS.length)),
              m.numberOfRanges >= 5 else { return nil }

        let quantity = lineNS.substring(with: m.range(at: 1))
        let sourceUnit = lineNS.substring(with: m.range(at: 2))
        let partialRange = m.range(at: 4)
        let partial = (partialRange.location == NSNotFound) ? "" : lineNS.substring(with: partialRange)

        // SI prefix generation recognizes pm/am as picometers/attometers.
        // A valid clock reading takes priority; explicit `picometers` and
        // quantities outside the clock-hour range still complete as units.
        guard !isClockTime(quantity + " " + sourceUnit),
              let category = UnitCategory.category(for: sourceUnit) else { return nil }
        let candidates = category.targetUnits
            .filter { $0.lowercased().hasPrefix(partial.lowercased()) }
            .filter { !UnitCategory.areEquivalent($0, sourceUnit) }
            .filter { $0.lowercased() != partial.lowercased() }

        guard let best = candidates.first else { return nil }
        return String(best.dropFirst(partial.count))
    }

    /// Recognizes one complete clock token, not a query or timezone name.
    /// Accepts `11pm`, `11 pm`, `2:30pm`, `4.30 pm`, `23:30`, `1430`,
    /// and Zulu forms such as `1430Z`. Hours and minutes must be valid.
    public static func isClockTime(_ text: String) -> Bool {
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let ns = token as NSString
        guard let match = clockRegex.firstMatch(in: token, range: NSRange(location: 0, length: ns.length)) else {
            return false
        }
        func integer(_ group: Int) -> Int? {
            let range = match.range(at: group)
            guard range.location != NSNotFound else { return nil }
            return Int(ns.substring(with: range))
        }
        if let hour = integer(1) {
            return (1...12).contains(hour) && (integer(2) ?? 0) <= 59
        }
        if let hour = integer(3), let minute = integer(4) {
            return hour <= 23 && minute <= 59
        }
        if let military = integer(5) {
            return military / 100 <= 23 && military % 100 <= 59
        }
        return false
    }

    private static let conversionRegex = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_:.,])([+\-]?\d+(?:[.,]\d+)?)\h*([A-Za-zµμ°][A-Za-z0-9°µμ_/^]*)\h+(in|to|as|into)\h+([A-Za-zµμ°][A-Za-z0-9°µμ_/^]*|)$"#,
        options: [.caseInsensitive]
    )
    private static let clockRegex = try! NSRegularExpression(
        pattern: #"^(?:(\d{1,2})(?:[:.](\d{2}))?\h*[ap]m|(\d{1,2}):(\d{2})z?|(\d{4})z?)$"#,
        options: [.caseInsensitive]
    )

    /// Curated "try this" demos shown as ghost text on a fresh blank
    /// document. Order is deliberately breadth-first across feature
    /// areas — each step in the rotation lands in a different category
    /// so a user who hits Tab a few times sees the *range* of what
    /// Vektor can do, not just three flavours of unit conversion.
    public static let demoHints: [String] = [
        // 1. Arithmetic — the universal hook
        "2 + 2",
        // 2. Currency — the headline "live data" moment
        "100 EUR in USD",
        // 3. Units — the bread-and-butter conversion
        "10 mi in km",
        // 4. Time — name a city, get the clock
        "Berlin time",
        // 5. Aviation — live METAR with best-runway append
        "METAR EDDM",
        // 6. Time-zone conversion (the deep one users miss)
        "0900 Munich time in Bali",
        // 7. Math functions
        "sqrt(2)",
        // 8. Speed conversion
        "120 kt in km/h",
        // 9. Date arithmetic
        "days between today and 2027-01-01",
        // 10. Crypto
        "1 BTC in USD",
        // 11. Aviation forecast
        "TAF KSFO",
        // 12. Decimal-time + glued am/pm + zone-to-zone
        "4.30pm Tokyo time in New York",
        // 13. Length conversion (aviation altitude)
        "60000 ft in m",
        // 14. Age from a date
        "age 1990-03-15",
        // 15. Runway directory
        "RWY EDDM",
        // 16. Percent
        "25% of 80",
        // 17. Zulu → local conversion
        "1430 Zulu in HKT",
        // 18. Pressure conversion
        "29.92 inHg in hPa",
        // 19. Sun times for an airport
        "sun EDDM",
        // 20. Weekday lookup
        "weekday 2027-07-04",
        // 21. Mass conversion
        "180 lbs in kg",
        // 22. "now in <zone> + offset"
        "now in Tokyo + 2h",
        // 23. Stock quote
        "stock AAPL",
        // 24. Date primitive
        "today",
        // 25. Temperature conversion
        "100 degF in degC",
        // 26. Comprehensive aviation briefing
        "briefing EDMA",
        // 27. Mixed-unit arithmetic
        "(5 km + 800 m) in miles",
        // 28. Duration from a quotient (h/min)
        "77/55 in hours",
        // 29. Density / pressure / field altitude
        "altitude EDDM",
        // 30. Variables — name a value, reuse it
        "rent = 1450 EUR",
        // 31. Roman numerals
        "MCMXC in dec",
        // 32. Number bases
        "0xFF in dec",
        // 33. Color interchange
        "#FF9F0F in rgb",
        // 34. Coordinate distance
        "distance 48.35,11.78 to 37.62,-122.37",
        // 35. Business days between
        "business days between today and 2027-01-01",
        // 36. Top of descent
        "TOD FL350 to FL080 at -1500 fpm GS 450",
        // 37. Wind components
        "wind 26 EDDM",
        // 38. Mortgage payment
        "mortgage 250000 EUR at 3.4% for 25 years",
        // 39. Compound interest
        "compound 10000 EUR at 7% for 30 years",
        // 40. List stats marker (the demo is just the marker —
        //     the user types the numbers below to see it work)
        "sum of:",
    ]

    /// Returns a demo hint for the given rotation index, wrapping
    /// modulo `demoHints.count`. Negative indices wrap correctly too —
    /// useful so the caller can pre-increment without bounds-checking.
    public static func demoHint(rotation: Int) -> String {
        let n = demoHints.count
        guard n > 0 else { return "" }
        return demoHints[((rotation % n) + n) % n]
    }
}

/// Physical-dimension grouping. Conversions only make sense between units in
/// the same group.
public enum UnitCategory: Sendable, CaseIterable {
    case length, mass, time, temperature, pressure, speed,
         force, energy, power, frequency, data, angle, volume, area

    /// Resolve a source-unit token to its category. Case- and plural-aware.
    public static func category(for raw: String) -> UnitCategory? {
        let key = raw.lowercased().trimmingCharacters(in: .whitespaces)
        return mapping[key]
    }

    /// Units offered for completion in this category. Common forms first
    /// (the first prefix match wins). Plurals included since they read more
    /// naturally and have aliases registered in `entry.js`.
    public var targetUnits: [String] {
        switch self {
        case .length:
            return [
                // SI metres and prefixes
                "meters", "kilometers", "centimeters", "millimeters",
                "decimeters", "decameters", "hectometers",
                "micrometers", "nanometers", "picometers",
                "megameters", "gigameters",
                "micron",
                // Imperial / nautical
                "inches", "feet", "yards", "miles",
                "nauticalmile", "NM", "nmi",
                // Esoteric but documented
                "fathom", "furlong", "league",
                "lightyear", "AU", "parsec",
            ]
        case .mass:
            return [
                "pounds", "kilograms", "grams", "milligrams",
                "decigrams", "centigrams", "decagrams", "hectograms",
                "micrograms", "nanograms",
                "megagrams",  // = tonne
                "ounces", "tons", "tonnes", "stone", "carats",
            ]
        case .volume:
            return [
                "liters", "milliliters", "deciliters", "centiliters",
                "hectoliters",
                "gallons", "pints", "quarts", "cups",
                "tablespoons", "teaspoons",
                "imperialgallon", "imperialpint",
                "cubicmeters", "cubicfeet", "cubicinches",
            ]
        case .area:
            return [
                "squaremeters", "squarekilometers", "squarecentimeters",
                "squarefeet", "squareyards", "squaremiles", "squareinches",
                "hectares", "acres",
            ]
        case .time:
            return [
                "seconds", "minutes", "hours", "days", "weeks",
                "months", "years",
                "milliseconds", "microseconds", "nanoseconds",
            ]
        case .temperature:
            return ["celsius", "fahrenheit", "kelvin", "degC", "degF", "K"]
        case .pressure:
            return [
                "hPa", "inHg", "mbar", "bar", "psi", "atm",
                "kPa", "Pa", "MPa", "GPa",
                "mmHg", "torr",
                "psf",
            ]
        case .speed:
            return [
                "mph", "knots", "km/h", "m/s",
                "kt", "kts", "kn", "kmh", "kph",
                // NOTE: "ft/min" is NOT a valid completion — math.js parses
                // `min` as the min() function, not minutes. `fpm` is the
                // registered unit.
                "ft/s", "fpm",
            ]
        case .force:
            return [
                "newtons", "kilonewtons", "millinewtons", "meganewtons",
                "dynes", "poundforce", "lbf", "kp", "kgf",
            ]
        case .energy:
            return [
                "joules", "kilojoules", "megajoules", "gigajoules",
                "millijoules",
                "calories", "kilocalories",
                "watthours", "kilowatthours", "megawatthours",
                "BTU", "electronvolt",
            ]
        case .power:
            return [
                "watts", "kilowatts", "megawatts", "gigawatts",
                "milliwatts",
                "horsepower", "metrichorsepower",
            ]
        case .frequency:
            return [
                "hertz", "kilohertz", "megahertz", "gigahertz", "terahertz",
                "millihertz",
                "rpm",
            ]
        case .data:
            return [
                "bytes", "kilobytes", "megabytes", "gigabytes", "terabytes", "petabytes",
                "kibibytes", "mebibytes", "gibibytes", "tebibytes",
                "bits", "kilobits", "megabits", "gigabits",
                "kbps", "Mbps", "Gbps",
            ]
        case .angle:
            return [
                "degrees", "radians", "grad",
                "arcminutes", "arcseconds",
                "cycle",
            ]
        }
    }

    /// Don't complete a conversion back into an alternate spelling of its
    /// source (`m` to `meters`, `ft` to `feet`, or `degC` to `celsius`).
    fileprivate static func areEquivalent(_ lhs: String, _ rhs: String) -> Bool {
        func key(_ raw: String) -> String {
            equivalentUnits.exact[raw] ?? equivalentUnits.folded[raw.lowercased()] ?? raw.lowercased()
        }
        return key(lhs) == key(rhs)
    }

    private static let siPrefixes: [(short: String, long: String)] = [
        ("Y","yotta"), ("Z","zetta"), ("E","exa"), ("P","peta"), ("T","tera"),
        ("G","giga"), ("M","mega"), ("k","kilo"), ("h","hecto"), ("da","deca"),
        ("",""),
        ("d","deci"), ("c","centi"), ("m","milli"), ("μ","micro"), ("u","micro"),
        ("n","nano"), ("p","pico"), ("f","femto"), ("a","atto"),
    ]

    private static let equivalentUnits: (exact: [String: String], folded: [String: String]) = {
        var exact: [String: String] = [:]
        var folded: [String: String] = [:]
        func add(_ names: [String], as key: String) {
            for name in names {
                exact[name] = key
                folded[name.lowercased()] = key
            }
        }
        // Preserve case for symbolic prefixes: mm and Mm share a dimension,
        // but are different units. Long names still match case-insensitively.
        for (symbol, name) in [("m", "meter"), ("g", "gram"), ("l", "liter"), ("s", "second"),
                               ("Pa", "pascal"), ("N", "newton"), ("J", "joule"), ("W", "watt"), ("Hz", "hertz")] {
            for (short, long) in siPrefixes {
                let key = long + name
                add([short + symbol, key, key + "s"], as: key)
                if symbol == "l" { add([short + "L"], as: key) }
                if long == "micro" { add(["µ" + symbol], as: key) }
            }
        }
        let groups: [(String, [String])] = [
            ("meter", ["metre", "metres"]),
            ("inch", ["in", "inch", "inches"]), ("foot", ["ft", "foot", "feet"]),
            ("yard", ["yd", "yard", "yards"]), ("mile", ["mi", "mile", "miles"]),
            ("nauticalmile", ["NM", "nmi", "nauticalmile", "nauticalmiles"]),
            ("pound", ["lb", "lbm", "lbs", "pound", "pounds"]),
            ("ounce", ["oz", "ounce", "ounces"]), ("tonne", ["tonne", "tonnes", "megagram", "megagrams"]),
            ("liter", ["litre", "litres"]), ("minute", ["min", "mins", "minute", "minutes"]),
            ("hour", ["h", "hr", "hrs", "hour", "hours"]), ("second", ["sec", "secs"]),
            ("celsius", ["celsius", "degC", "°C"]), ("fahrenheit", ["fahrenheit", "degF", "°F"]),
            ("kelvin", ["K", "kelvin"]), ("knot", ["kt", "kts", "kn", "knot", "knots"]),
            ("mph", ["mph"]), ("km/h", ["km/h", "kmh", "kph"]), ("m/s", ["m/s", "mps"]),
            ("byte", ["B", "byte", "bytes"]), ("bit", ["b", "bit", "bits"]),
            ("degree", ["deg", "degree", "degrees"]), ("radian", ["rad", "radian", "radians"]),
            ("squaremeter", ["m^2", "squaremeter", "squaremeters"]),
            ("squarekilometer", ["km^2", "squarekilometer", "squarekilometers"]),
            ("squarecentimeter", ["cm^2", "squarecentimeter", "squarecentimeters"]),
            ("squarefoot", ["ft^2", "squarefoot", "squarefeet"]),
        ]
        for (key, names) in groups { add(names, as: key) }
        return (exact, folded)
    }()

    /// Master source-recognition table. Generated programmatically from base
    /// units + SI prefixes so every documented unit (decimeter, decagram,
    /// hectoliter, milliwatt, nanosecond, …) is picked up as a source.
    private static let mapping: [String: UnitCategory] = {
        var m: [String: UnitCategory] = [:]
        let add: (UnitCategory, [String]) -> Void = { cat, names in
            for n in names { m[n.lowercased()] = cat }
        }

        // Helper: register a base unit and all its SI-prefixed forms.
        let addSI: (UnitCategory, String, String, [String]) -> Void = { cat, shortBase, longBase, extras in
            for (sp, lp) in siPrefixes {
                add(cat, ["\(sp)\(shortBase)", "\(lp)\(longBase)", "\(lp)\(longBase)s"])
            }
            add(cat, extras)
        }

        // ── Length ──────────────────────────────────────────────────────
        addSI(.length, "m", "meter", [
            "metre", "metres",
            "inch", "inches", "ft", "foot", "feet", "yd", "yard", "yards",
            "mi", "mile", "miles",
            "NM", "nmi", "nauticalmile", "nauticalmiles",
            "fathom", "fathoms", "furlong", "furlongs", "league", "leagues",
            "ly", "lightyear", "lightyears",
            "AU", "parsec", "parsecs",
            "micron", "microns",
            "angstrom", "angstroms",
        ])

        // ── Mass ────────────────────────────────────────────────────────
        addSI(.mass, "g", "gram", [
            "gramme", "grammes",
            "lb", "lbm", "lbs", "pound", "pounds",
            "oz", "ounce", "ounces",
            "ton", "tons", "tonne", "tonnes",
            "stone", "stones",
            "carat", "carats", "ct",
            "grain", "grains", "dram", "drams",
            "slug", "slugs",
        ])

        // ── Volume ──────────────────────────────────────────────────────
        addSI(.volume, "l", "liter", [
            "litre", "litres",
            "gallon", "gallons", "pint", "pints",
            "quart", "quarts", "cup", "cups",
            "tablespoon", "tablespoons", "tbsp",
            "teaspoon", "teaspoons", "tsp",
            "imperialgallon", "imperialpint",
            "cuin", "cubicinch", "cubicinches",
            "cubicfoot", "cubicfeet",
            "cubicmeter", "cubicmeters",
        ])

        // ── Time ────────────────────────────────────────────────────────
        // Time doesn't follow SI prefixing for h/min/day, so handle directly.
        addSI(.time, "s", "second", [
            "min", "mins", "minute", "minutes",
            "h", "hr", "hrs", "hour", "hours",
            "day", "days", "week", "weeks",
            "month", "months", "year", "years",
        ])

        // ── Temperature ────────────────────────────────────────────────
        add(.temperature, [
            "celsius", "fahrenheit", "kelvin",
            "degc", "degf", "k", "°c", "°f",
            "rankine", "degr",
        ])

        // ── Pressure ───────────────────────────────────────────────────
        addSI(.pressure, "Pa", "pascal", [
            "bar", "mbar", "millibar", "millibars",
            "atm", "atmosphere", "atmospheres",
            "psi", "psf",
            "inhg", "mmhg", "torr",
        ])

        // ── Speed (multiple compound spellings) ────────────────────────
        add(.speed, [
            "kt", "kts", "kn", "knot", "knots",
            "mph", "kmh", "kph", "km/h", "m/s", "mps",
            "ft/s", "ft/min", "ft/sec",
        ])

        // ── Force ──────────────────────────────────────────────────────
        addSI(.force, "N", "newton", [
            "dyne", "dynes",
            "lbf", "kp", "kgf", "poundforce",
            "kip",
        ])

        // ── Energy ─────────────────────────────────────────────────────
        addSI(.energy, "J", "joule", [
            "calorie", "calories", "cal", "kcal",
            "kilocalorie", "kilocalories",
            "wh", "watthour", "watthours",
            "kwh", "kilowatthour", "kilowatthours",
            "mwh", "megawatthour",
            "btu", "electronvolt", "ev",
            "ftlb", "footpound",
        ])

        // ── Power ──────────────────────────────────────────────────────
        addSI(.power, "W", "watt", [
            "hp", "horsepower",
            "ps", "metrichorsepower",
            "kva",
        ])

        // ── Frequency ──────────────────────────────────────────────────
        addSI(.frequency, "Hz", "hertz", [
            "rpm",
        ])

        // ── Data ───────────────────────────────────────────────────────
        // Both binary (KiB, MiB) and decimal (kB, MB) variants.
        let dataBase = ["bit", "byte"]
        for base in dataBase {
            add(.data, [base, base + "s"])
            for (sp, lp) in siPrefixes where !sp.isEmpty {
                add(.data, ["\(sp)\(base)", "\(lp)\(base)", "\(lp)\(base)s"])
            }
        }
        add(.data, [
            "b", "B", "kb", "kB", "mb", "MB", "gb", "GB", "tb", "TB", "pb", "PB",
            "kib", "KiB", "mib", "MiB", "gib", "GiB", "tib", "TiB",
            "kbit", "Mbit", "Gbit",
            "kbps", "Mbps", "Gbps",
        ])

        // ── Angle ──────────────────────────────────────────────────────
        add(.angle, [
            "rad", "radian", "radians",
            "deg", "degree", "degrees",
            "grad", "grads", "gradian", "gradians",
            "arcsec", "arcseconds", "arcmin", "arcminutes",
            "cycle", "cycles", "rev", "revolution", "revolutions",
        ])

        // ── Area ───────────────────────────────────────────────────────
        add(.area, [
            "hectare", "hectares", "acre", "acres",
            "m^2", "km^2", "cm^2", "ft^2", "yd^2", "in^2", "mi^2",
            "squaremeter", "squaremeters",
            "squarefoot", "squarefeet",
            "squareyard", "squareyards",
            "squarekilometer", "squarekilometers",
        ])

        return m
    }()
}
