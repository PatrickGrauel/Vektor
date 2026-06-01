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
        let head = ns.substring(with: NSRange(location: 0, length: cursor))

        // Restrict the regex to the current line.
        let lineRange = (head as NSString).lineRange(for: NSRange(location: (head as NSString).length, length: 0))
        let line = (head as NSString).substring(with: lineRange)

        // Pattern: "<number> <sourceUnit> <in|to> <partialTarget>"
        // sourceUnit and target accept letters, slashes (for km/h), digits
        // (m^2-style), and underscores.
        let pattern = #"(\d+(?:[.,]\d+)?)\s*([A-Za-zµμ°][A-Za-z0-9°µμ_/^]*)\s+(in|to)\s+([A-Za-zµμ°][A-Za-z0-9°µμ_/^]*|)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let lineNS = line as NSString
        guard let m = regex.firstMatch(in: line, range: NSRange(location: 0, length: lineNS.length)),
              m.numberOfRanges >= 5 else { return nil }

        let sourceUnit = lineNS.substring(with: m.range(at: 2))
        let partialRange = m.range(at: 4)
        let partial = (partialRange.location == NSNotFound) ? "" : lineNS.substring(with: partialRange)

        guard let category = UnitCategory.category(for: sourceUnit) else { return nil }
        let candidates = category.targetUnits
            .filter { $0.lowercased().hasPrefix(partial.lowercased()) }
            .filter { $0.lowercased() != sourceUnit.lowercased() }
            .filter { $0.lowercased() != partial.lowercased() }

        guard let best = candidates.first else { return nil }
        return String(best.dropFirst(partial.count))
    }

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
        "100°F in °C",
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
public enum UnitCategory: Sendable {
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
                "nautical_mile", "NM", "nmi",
                // Esoteric but documented
                "fathom", "furlong", "league",
                "light_year", "AU", "parsec",
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
                "imperial_gallon", "imperial_pint",
                "cubic_meters", "cubic_feet", "cubic_inches",
            ]
        case .area:
            return [
                "square_meters", "square_kilometers", "square_centimeters",
                "square_feet", "square_yards", "square_miles", "square_inches",
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
                "ft/s", "ft/min",
            ]
        case .force:
            return [
                "newtons", "kilonewtons", "millinewtons", "meganewtons",
                "dynes", "pound_force", "lbf", "kp", "kgf",
            ]
        case .energy:
            return [
                "joules", "kilojoules", "megajoules", "gigajoules",
                "millijoules",
                "calories", "kilocalories",
                "watt_hours", "kilowatt_hours", "megawatt_hours",
                "BTU", "electronvolt",
            ]
        case .power:
            return [
                "watts", "kilowatts", "megawatts", "gigawatts",
                "milliwatts",
                "horsepower", "metric_horsepower",
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

    /// Master source-recognition table. Generated programmatically from base
    /// units + SI prefixes so every documented unit (decimeter, decagram,
    /// hectoliter, milliwatt, nanosecond, …) is picked up as a source.
    private static let mapping: [String: UnitCategory] = {
        var m: [String: UnitCategory] = [:]
        let add: (UnitCategory, [String]) -> Void = { cat, names in
            for n in names { m[n.lowercased()] = cat }
        }

        // SI prefixes: short + long form.
        let siPrefixes: [(short: String, long: String)] = [
            ("Y","yotta"), ("Z","zetta"), ("E","exa"), ("P","peta"), ("T","tera"),
            ("G","giga"), ("M","mega"), ("k","kilo"), ("h","hecto"), ("da","deca"),
            ("",""),                                           // base
            ("d","deci"), ("c","centi"), ("m","milli"), ("μ","micro"), ("u","micro"),
            ("n","nano"), ("p","pico"), ("f","femto"), ("a","atto"),
        ]

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
            "NM", "nmi", "nautical_mile", "nautical_miles",
            "fathom", "fathoms", "furlong", "furlongs", "league", "leagues",
            "ly", "light_year", "light_years",
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
            "imperial_gallon", "imperial_pint",
            "cuin", "cubic_inch", "cubic_inches",
            "cubic_foot", "cubic_feet",
            "cubic_meter", "cubic_meters",
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
            "lbf", "kp", "kgf", "pound_force",
            "kip",
        ])

        // ── Energy ─────────────────────────────────────────────────────
        addSI(.energy, "J", "joule", [
            "calorie", "calories", "cal", "kcal",
            "kilocalorie", "kilocalories",
            "wh", "watt_hour", "watt_hours",
            "kwh", "kilowatt_hour", "kilowatt_hours",
            "mwh", "megawatt_hour",
            "btu", "electronvolt", "ev",
            "ftlb", "foot_pound",
        ])

        // ── Power ──────────────────────────────────────────────────────
        addSI(.power, "W", "watt", [
            "hp", "horsepower",
            "ps", "metric_horsepower",
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
            "square_meter", "square_meters",
            "square_foot", "square_feet",
            "square_yard", "square_yards",
            "square_kilometer", "square_kilometers",
        ])

        return m
    }()
}
