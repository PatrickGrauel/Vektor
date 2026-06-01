import Foundation
import VektorAviation

// Small self-contained line handlers — each one recognises a specific
// pattern, returns a formatted string, and returns nil to let the next
// handler in the engine's chain try. Grouped here so NumiEngine.swift
// doesn't keep growing every time we add a new "calculator that thinks
// too much" trick.

extension NumiEngine {

    // MARK: - Roman numerals
    //
    //   MCMXC in dec  → 1990
    //   1990 in roman → MCMXC
    //
    // Bounded to the classical 1..3999 range — anything beyond would
    // need vinculum / bar notation which most users wouldn't type.

    private static let romanValues: [(symbol: String, value: Int)] = [
        ("M", 1000), ("CM", 900), ("D", 500), ("CD", 400),
        ("C", 100),  ("XC", 90),  ("L", 50),  ("XL", 40),
        ("X", 10),   ("IX", 9),   ("V", 5),   ("IV", 4), ("I", 1),
    ]

    static func handleRomanLine(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let ns = trimmed as NSString
        let full = NSRange(location: 0, length: ns.length)

        // Integer → Roman
        if let re = try? NSRegularExpression(pattern: #"^(\d{1,4})\s+in\s+roman$"#,
                                              options: [.caseInsensitive]),
           let m = re.firstMatch(in: trimmed, range: full),
           let n = Int(ns.substring(with: m.range(at: 1))),
           (1...3999).contains(n) {
            return intToRoman(n)
        }

        // Roman → Integer
        if let re = try? NSRegularExpression(pattern: #"^([IVXLCDMivxlcdm]+)\s+in\s+dec$"#),
           let m = re.firstMatch(in: trimmed, range: full),
           let value = romanToInt(ns.substring(with: m.range(at: 1)).uppercased()) {
            return String(value)
        }

        return nil
    }

    private static func intToRoman(_ n: Int) -> String {
        var result = ""
        var remaining = n
        for (symbol, value) in romanValues {
            while remaining >= value {
                result += symbol
                remaining -= value
            }
        }
        return result
    }

    private static func romanToInt(_ s: String) -> Int? {
        var result = 0
        var i = s.startIndex
        while i < s.endIndex {
            let next = s.index(after: i)
            if next < s.endIndex {
                let twoChar = String(s[i...next])
                if let value = romanValues.first(where: { $0.symbol == twoChar })?.value {
                    result += value
                    i = s.index(i, offsetBy: 2)
                    continue
                }
            }
            let oneChar = String(s[i])
            guard let value = romanValues.first(where: { $0.symbol == oneChar })?.value else {
                return nil
            }
            result += value
            i = next
        }
        guard (1...3999).contains(result) else { return nil }
        // Round-trip check: re-encode and compare to catch invalid forms
        // (e.g. "IIII" → 4 but the canonical form is "IV"). Without this
        // we'd accept any garbage like "VVVV" as 20.
        return intToRoman(result) == s.uppercased() ? result : nil
    }

    // MARK: - Number bases
    //
    //   0xFF in dec   → 255
    //   255 in hex    → 0xFF
    //   0b1011 in dec → 11
    //   0o17 in dec   → 15
    //   255 in bin    → 0b11111111
    //
    // Accepts 0x / 0b / 0o prefixes for the source; bare digits are
    // treated as decimal. Targets: dec / hex / bin / oct.

    static func handleBasesLine(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let pattern = #"^([+-]?(?:0[xXbBoO][0-9A-Fa-f]+|\d+))\s+in\s+(dec|hex|bin|oct)$"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: trimmed,
                                    range: NSRange(location: 0, length: (trimmed as NSString).length))
        else { return nil }
        let ns = trimmed as NSString
        let token = ns.substring(with: m.range(at: 1))
        let target = ns.substring(with: m.range(at: 2)).lowercased()
        guard let value = parseBasedInt(token) else { return nil }
        switch target {
        case "dec": return String(value)
        case "hex": return "0x" + String(value, radix: 16, uppercase: true)
        case "bin": return "0b" + String(value, radix: 2)
        case "oct": return "0o" + String(value, radix: 8)
        default:    return nil
        }
    }

    private static func parseBasedInt(_ s: String) -> Int? {
        let isNeg = s.hasPrefix("-")
        let body = (isNeg || s.hasPrefix("+")) ? String(s.dropFirst()) : s
        let lower = body.lowercased()
        let value: Int?
        if lower.hasPrefix("0x") { value = Int(lower.dropFirst(2), radix: 16) }
        else if lower.hasPrefix("0b") { value = Int(lower.dropFirst(2), radix: 2) }
        else if lower.hasPrefix("0o") { value = Int(lower.dropFirst(2), radix: 8) }
        else { value = Int(lower, radix: 10) }
        guard let v = value else { return nil }
        return isNeg ? -v : v
    }

    // MARK: - Color interchange
    //
    //   #FF9F0F in rgb        → rgb(255, 159, 15)
    //   #FF9F0F in hsl        → hsl(36, 100%, 53%)
    //   rgb(255,159,15) in hex → #FF9F0F
    //   hsl(36, 100%, 53%) in hex → #FF9F0F
    //
    // Accepts 3- or 6-digit hex (with or without #), `rgb(r,g,b)`,
    // `hsl(h,s%,l%)`. Output uses the canonical comma-separated form
    // for rgb / hsl and uppercase 6-digit for hex.

    private struct Color3 { let r, g, b: Int }

    static func handleColorLine(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let pattern = #"^(.+?)\s+in\s+(hex|rgb|hsl)$"#
        guard let re = try? NSRegularExpression(pattern: pattern,
                                                 options: [.caseInsensitive]),
              let m = re.firstMatch(in: trimmed,
                                    range: NSRange(location: 0, length: (trimmed as NSString).length))
        else { return nil }
        let ns = trimmed as NSString
        let source = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
        let target = ns.substring(with: m.range(at: 2)).lowercased()
        guard let color = parseColor(source) else { return nil }
        switch target {
        case "hex": return formatColorHex(color)
        case "rgb": return formatColorRGB(color)
        case "hsl": return formatColorHSL(color)
        default:    return nil
        }
    }

    private static func parseColor(_ s: String) -> Color3? {
        // Hex (with or without leading #), 3-digit or 6-digit
        if let re = try? NSRegularExpression(pattern: #"^#?([0-9A-Fa-f]{6}|[0-9A-Fa-f]{3})$"#),
           let m = re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) {
            var hex = (s as NSString).substring(with: m.range(at: 1))
            if hex.count == 3 {
                // "F9F" → "FF99FF" (each nibble doubles)
                hex = String(hex.flatMap { [$0, $0] })
            }
            if let v = Int(hex, radix: 16) {
                return Color3(r: (v >> 16) & 0xFF, g: (v >> 8) & 0xFF, b: v & 0xFF)
            }
        }
        // rgb(r, g, b)
        if let re = try? NSRegularExpression(pattern: #"^rgb\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\)$"#,
                                              options: [.caseInsensitive]),
           let m = re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) {
            let ns = s as NSString
            guard let r = Int(ns.substring(with: m.range(at: 1))),
                  let g = Int(ns.substring(with: m.range(at: 2))),
                  let b = Int(ns.substring(with: m.range(at: 3))),
                  (0...255).contains(r), (0...255).contains(g), (0...255).contains(b)
            else { return nil }
            return Color3(r: r, g: g, b: b)
        }
        // hsl(h, s%, l%) — % is optional on parse, required on output
        if let re = try? NSRegularExpression(pattern: #"^hsl\(\s*(\d+(?:\.\d+)?)\s*,\s*(\d+(?:\.\d+)?)%?\s*,\s*(\d+(?:\.\d+)?)%?\s*\)$"#,
                                              options: [.caseInsensitive]),
           let m = re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) {
            let ns = s as NSString
            guard let h = Double(ns.substring(with: m.range(at: 1))),
                  let s = Double(ns.substring(with: m.range(at: 2))),
                  let l = Double(ns.substring(with: m.range(at: 3))),
                  (0...360).contains(h), (0...100).contains(s), (0...100).contains(l)
            else { return nil }
            return hslToColor(h: h, s: s / 100, l: l / 100)
        }
        return nil
    }

    private static func formatColorHex(_ c: Color3) -> String {
        String(format: "#%02X%02X%02X", c.r, c.g, c.b)
    }

    private static func formatColorRGB(_ c: Color3) -> String {
        "rgb(\(c.r), \(c.g), \(c.b))"
    }

    private static func formatColorHSL(_ c: Color3) -> String {
        let rN = Double(c.r) / 255
        let gN = Double(c.g) / 255
        let bN = Double(c.b) / 255
        let maxC = max(rN, gN, bN)
        let minC = min(rN, gN, bN)
        let l = (maxC + minC) / 2
        let s: Double
        let h: Double
        if maxC == minC {
            s = 0
            h = 0
        } else {
            let d = maxC - minC
            s = l > 0.5 ? d / (2 - maxC - minC) : d / (maxC + minC)
            switch maxC {
            case rN: h = (gN - bN) / d + (gN < bN ? 6 : 0)
            case gN: h = (bN - rN) / d + 2
            default: h = (rN - gN) / d + 4
            }
        }
        return "hsl(\(Int(round(h * 60))), \(Int(round(s * 100)))%, \(Int(round(l * 100)))%)"
    }

    private static func hslToColor(h: Double, s: Double, l: Double) -> Color3 {
        let hh = h / 360
        let r, g, b: Double
        if s == 0 {
            r = l; g = l; b = l
        } else {
            func hue2rgb(_ p: Double, _ q: Double, _ t: Double) -> Double {
                var t = t
                if t < 0 { t += 1 }
                if t > 1 { t -= 1 }
                if t < 1.0/6 { return p + (q - p) * 6 * t }
                if t < 1.0/2 { return q }
                if t < 2.0/3 { return p + (q - p) * (2.0/3 - t) * 6 }
                return p
            }
            let q = l < 0.5 ? l * (1 + s) : l + s - l * s
            let p = 2 * l - q
            r = hue2rgb(p, q, hh + 1.0/3)
            g = hue2rgb(p, q, hh)
            b = hue2rgb(p, q, hh - 1.0/3)
        }
        return Color3(r: Int(round(r * 255)),
                      g: Int(round(g * 255)),
                      b: Int(round(b * 255)))
    }

    // MARK: - Distance between coordinates
    //
    //   distance 48.35,11.78 to 37.62,-122.37
    //   distance 48.35,11.78 to 37.62,-122.37 in km
    //
    // Sibling of the airport-based `handleDistanceLine`. Tried first in
    // the chain — coordinate format never collides with ICAO/IATA so
    // the two patterns are mutually exclusive. Defaults to NM (pilot
    // default) when no unit is specified, matching the airport version.

    static func handleCoordinateDistanceLine(_ line: String) -> String? {
        let pattern = #"^(?:distance|dist)\s+(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s+(?:to|→)\s+(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)(?:\s+in\s+([A-Za-z]+))?$"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: line,
                                    range: NSRange(location: 0, length: (line as NSString).length))
        else { return nil }
        let ns = line as NSString
        guard let lat1 = Double(ns.substring(with: m.range(at: 1))),
              let lon1 = Double(ns.substring(with: m.range(at: 2))),
              let lat2 = Double(ns.substring(with: m.range(at: 3))),
              let lon2 = Double(ns.substring(with: m.range(at: 4))) else { return nil }
        guard (-90...90).contains(lat1), (-90...90).contains(lat2),
              (-180...180).contains(lon1), (-180...180).contains(lon2) else {
            return "invalid coordinates (lat must be ±90, lon ±180)"
        }
        let unitToken: String? = {
            let r = m.range(at: 5)
            return r.location == NSNotFound ? nil : ns.substring(with: r).lowercased()
        }()
        let bearing = GreatCircle.initialBearingTrue(lat1: lat1, lon1: lon1, lat2: lat2, lon2: lon2)
        let formatted: String
        switch unitToken {
        case "km":
            let km = GreatCircle.distanceKM(lat1: lat1, lon1: lon1, lat2: lat2, lon2: lon2)
            formatted = String(format: "%.0f km", km)
        case "mi", "mile", "miles":
            let mi = GreatCircle.distanceMiles(lat1: lat1, lon1: lon1, lat2: lat2, lon2: lon2)
            formatted = String(format: "%.0f mi", mi)
        case nil, "nm", "nmi", "nauticalmile", "nauticalmiles":
            let nm = GreatCircle.distanceNM(lat1: lat1, lon1: lon1, lat2: lat2, lon2: lon2)
            formatted = String(format: "%.0f NM", nm)
        default:
            let nm = GreatCircle.distanceNM(lat1: lat1, lon1: lon1, lat2: lat2, lon2: lon2)
            formatted = String(format: "%.0f NM (unknown unit '\(unitToken ?? "")')", nm)
        }
        return String(format: "%@ · brg %03.0f° T", formatted, bearing)
    }

    // MARK: - Top of descent
    //
    //   TOD FL350 to FL080 at -1500 fpm GS 450
    //   TOD 35000 ft to 8000 ft at -1500 fpm GS 450
    //
    // The classic pilot calculation: given a starting altitude, target
    // altitude, vertical rate, and ground speed — how many NM out do
    // I start the descent? Heuristic: any altitude ≤ 600 is treated as
    // a Flight Level (multiply by 100); otherwise as feet directly.

    static func handleTopOfDescentLine(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let pattern = #"^tod\s+(?:fl\s*)?(\d+)(?:\s*ft)?\s+to\s+(?:fl\s*)?(\d+)(?:\s*ft)?\s+at\s+(-?\d+)\s*fpm\s+gs\s+(\d+)$"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: trimmed,
                                    range: NSRange(location: 0, length: (trimmed as NSString).length))
        else { return nil }
        let ns = trimmed as NSString
        guard let alt1 = Int(ns.substring(with: m.range(at: 1))),
              let alt2 = Int(ns.substring(with: m.range(at: 2))),
              let fpm  = Int(ns.substring(with: m.range(at: 3))),
              let gs   = Int(ns.substring(with: m.range(at: 4)))
        else { return nil }
        let altFt1 = alt1 <= 600 ? alt1 * 100 : alt1
        let altFt2 = alt2 <= 600 ? alt2 * 100 : alt2
        let altDiff = abs(altFt1 - altFt2)
        let absRate = abs(fpm)
        guard absRate > 0, gs > 0 else { return nil }
        let timeMin = Double(altDiff) / Double(absRate)
        let distanceNM = Double(gs) * timeMin / 60
        let mins = Int(timeMin)
        let secs = Int(round((timeMin - Double(mins)) * 60))
        return String(format: "%.1f NM · %dmin %02dsec (%d ft at %d fpm, GS %d)",
                      distanceNM, mins, secs, altDiff, absRate, gs)
    }

    // MARK: - Runway wind components
    //
    //   wind 26 EDDM      → HW 12 kt · XW 8 kt R   RWY 26 @ 263° T · wind 240°/15 kt
    //   wind 09L KSFO     → … (works with L/R/C suffixes too)
    //
    // Instance method (not static) because it needs the MainActor-isolated
    // MetarCacheBridge. Triangulates a live wind direction against the
    // requested runway's true heading and returns the projected head /
    // tail / cross components in knots.
    //
    // Sign convention follows the standard pilot mental model:
    //   • HW (positive cos) vs TW (negative cos) for headwind / tailwind
    //   • "from right" (positive sin) vs "from left" (negative sin) for
    //     the crosswind side — i.e. which way the wind pushes the airframe
    //     during the landing roll.

    func handleWindLine(_ line: String) -> MetarLine? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let pattern = #"^wind\s+([0-9]{1,2}[LRC]?)\s+([A-Z]{3,4})$"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: trimmed,
                                    range: NSRange(location: 0, length: (trimmed as NSString).length))
        else { return nil }
        let ns = trimmed as NSString
        let runwayIdent = ns.substring(with: m.range(at: 1)).uppercased()
        let icao = ns.substring(with: m.range(at: 2)).uppercased()
        let canonical = AirportCodeMap.canonicalICAO(from: icao) ?? icao

        let runways = RunwayDatabase.shared.runways(forICAO: canonical)
        guard !runways.isEmpty else {
            return MetarLine(value: "no runways found for \(canonical)", annotation: nil)
        }

        // Try exact ident first (e.g. "09L"); if user typed "09" but
        // the database only has parallel runways like "09L"/"09R",
        // fall back to a digits-only match against the first parallel.
        let heading: Double? = {
            for r in runways {
                if r.leIdent.uppercased() == runwayIdent { return r.leHeadingTrue }
                if r.heIdent.uppercased() == runwayIdent { return r.heHeadingTrue }
            }
            for r in runways {
                let leDigits = r.leIdent.trimmingCharacters(in: .letters)
                let heDigits = r.heIdent.trimmingCharacters(in: .letters)
                if leDigits == runwayIdent { return r.leHeadingTrue }
                if heDigits == runwayIdent { return r.heHeadingTrue }
            }
            return nil
        }()
        guard let runwayHeading = heading else {
            return MetarLine(value: "runway \(runwayIdent) not found at \(canonical)",
                             annotation: nil)
        }

        let bridge = MetarCacheBridge.shared
        guard let cached = MainActor.assumeIsolated({ bridge.cached(kind: .metar, icao: canonical) }) else {
            MainActor.assumeIsolated { bridge.prefetch(kind: .metar, icao: canonical) }
            return MetarLine(value: "fetching METAR for \(canonical)…", annotation: nil)
        }
        let decoded = MetarParser.parse(cached.raw)
        guard let wind = decoded.wind else {
            return MetarLine(value: "no wind data in METAR", annotation: nil)
        }
        if wind.isVariable {
            let range = wind.variableRange.map { "\($0.0)–\($0.1)° " } ?? ""
            return MetarLine(value: "wind variable \(range)@ \(wind.speedKt) kt — components depend on direction",
                             annotation: nil)
        }
        guard let fromDeg = wind.fromDeg else {
            return MetarLine(value: "wind direction unavailable", annotation: nil)
        }
        if wind.speedKt == 0 {
            return MetarLine(value: "calm wind · RWY \(runwayIdent) @ \(String(format: "%03.0f", runwayHeading))° T",
                             annotation: nil)
        }

        let delta = Self.signedAngleDelta(from: runwayHeading, to: Double(fromDeg))
        let rad = delta * .pi / 180
        let head = Double(wind.speedKt) * cos(rad)
        let cross = Double(wind.speedKt) * sin(rad)

        let headLabel = head >= 0 ? "HW" : "TW"
        let crossLabel = cross >= 0 ? "from right" : "from left"

        var output = String(format: "%@ %.0f kt · XW %.0f kt %@   RWY %@ @ %03.0f° T · wind %d°/%d kt",
                            headLabel, abs(head),
                            abs(cross), crossLabel,
                            runwayIdent, runwayHeading,
                            fromDeg, wind.speedKt)
        if let gust = wind.gustKt {
            let gustHead = Double(gust) * cos(rad)
            let gustCross = Double(gust) * sin(rad)
            output += String(format: "  (gusts: %@ %.0f / XW %.0f)",
                             gustHead >= 0 ? "HW" : "TW", abs(gustHead), abs(gustCross))
        }
        return MetarLine(value: output, annotation: nil)
    }

    /// Signed angular difference from `a` to `b`, normalized to (-180, 180].
    /// Positive when `b` is clockwise of `a`. Used by the wind-components
    /// math to pick the correct sin / cos sign for headwind / crosswind.
    private static func signedAngleDelta(from a: Double, to b: Double) -> Double {
        var d = b - a
        while d > 180 { d -= 360 }
        while d <= -180 { d += 360 }
        return d
    }

    // MARK: - Mortgage payment
    //
    //   mortgage 250000 EUR at 3.4% for 25 years
    //   mortgage 500000 at 4.5% for 30 years   (currency optional)
    //
    // Standard fixed-rate amortising loan formula. Returns monthly
    // payment plus the lifetime totals so the user gets the full
    // picture in one line rather than a separate "what's the total
    // interest" follow-up.

    static func handleMortgageLine(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let pattern = #"^mortgage\s+([\d.,]+)\s*([A-Z]{3})?\s+at\s+([\d.]+)\s*%\s+for\s+([\d.]+)\s+years?$"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: trimmed,
                                    range: NSRange(location: 0, length: (trimmed as NSString).length))
        else { return nil }
        let ns = trimmed as NSString
        let principalStr = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: ",", with: "")
        let currency: String = {
            let r = m.range(at: 2)
            return r.location == NSNotFound ? "" : " " + ns.substring(with: r).uppercased()
        }()
        guard let P = Double(principalStr),
              let annualRate = Double(ns.substring(with: m.range(at: 3))),
              let years = Double(ns.substring(with: m.range(at: 4))),
              P > 0, annualRate >= 0, years > 0
        else { return nil }
        let r = annualRate / 100 / 12
        let n = years * 12
        let payment: Double
        if r == 0 {
            payment = P / n
        } else {
            let factor = pow(1 + r, n)
            payment = P * r * factor / (factor - 1)
        }
        let totalPaid = payment * n
        let interest = totalPaid - P
        let nf = financialFormatter()
        return "\(nf.string(from: NSNumber(value: payment)) ?? "")\(currency)/mo  ·  \(nf.string(from: NSNumber(value: interest)) ?? "")\(currency) interest  ·  \(nf.string(from: NSNumber(value: totalPaid)) ?? "")\(currency) total over \(formatYears(years))"
    }

    // MARK: - Compound interest
    //
    //   compound 100 EUR at 5% for 10 years
    //   compound 250000 at 7% for 30 years
    //
    // Simple annual-compounding future value. Returns the final
    // value plus the absolute growth and the multiple — a 1.5× hint
    // is more useful than "162.89 EUR" alone when you're trying to
    // build intuition about long-horizon returns.

    static func handleCompoundLine(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let pattern = #"^compound\s+([\d.,]+)\s*([A-Z]{3})?\s+at\s+([\d.]+)\s*%\s+for\s+([\d.]+)\s+years?$"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: trimmed,
                                    range: NSRange(location: 0, length: (trimmed as NSString).length))
        else { return nil }
        let ns = trimmed as NSString
        let principalStr = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: ",", with: "")
        let currency: String = {
            let r = m.range(at: 2)
            return r.location == NSNotFound ? "" : " " + ns.substring(with: r).uppercased()
        }()
        guard let P = Double(principalStr),
              let annualRate = Double(ns.substring(with: m.range(at: 3))),
              let years = Double(ns.substring(with: m.range(at: 4))),
              P > 0, years > 0
        else { return nil }
        let r = annualRate / 100
        let FV = P * pow(1 + r, years)
        let growth = FV - P
        let mult = FV / P
        let nf = financialFormatter()
        return "\(nf.string(from: NSNumber(value: FV)) ?? "")\(currency)  ·  +\(nf.string(from: NSNumber(value: growth)) ?? "")\(currency) growth  ·  \(String(format: "%.2fx", mult)) over \(formatYears(years))"
    }

    private static func financialFormatter() -> NumberFormatter {
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        nf.minimumFractionDigits = 2
        nf.maximumFractionDigits = 2
        nf.groupingSeparator = ","
        return nf
    }

    private static func formatYears(_ y: Double) -> String {
        if y == y.rounded() {
            return "\(Int(y)) yr"
        }
        return String(format: "%.1f yr", y)
    }

    // MARK: - List statistics
    //
    //   sum of:                  ← marker line; result lands here
    //   10                       ← these lines are also evaluated
    //   20                          normally (so they show their own
    //   30                          gutter values) AND fed into the
    //                            aggregate above.
    //
    // Supported operators: sum / mean / avg / average / median / min /
    // max / stddev. Peek-ahead scans contiguous bare-numeric lines
    // (`-?\d+(\.\d+)?`) below the marker until it hits a blank line,
    // a comment, a header, or anything non-numeric. v1 deliberately
    // does NOT evaluate expressions inside the block — keeping it as
    // "literal numbers only" makes the behavior predictable and lets
    // the user reason about what's being aggregated at a glance.

    static func handleListStatsLine(_ line: String,
                                    lines: [String],
                                    currentIndex: Int) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let pattern = #"^(sum|mean|avg|average|median|min|max|stddev|stdev)\s+of\s*:?\s*$"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: trimmed,
                                    range: NSRange(location: 0, length: (trimmed as NSString).length))
        else { return nil }
        let op = (trimmed as NSString).substring(with: m.range(at: 1)).lowercased()

        guard let numberRegex = try? NSRegularExpression(pattern: #"^-?\d+(?:[.,]\d+)?$"#) else {
            return nil
        }
        var values: [Double] = []
        var i = currentIndex + 1
        while i < lines.count {
            let next = lines[i].trimmingCharacters(in: .whitespaces)
            if next.isEmpty || next.hasPrefix("//") || next.hasPrefix("#") { break }
            let nextNs = next as NSString
            guard numberRegex.firstMatch(in: next,
                                          range: NSRange(location: 0, length: nextNs.length)) != nil
            else { break }
            let normalized = next.replacingOccurrences(of: ",", with: ".")
            guard let v = Double(normalized) else { break }
            values.append(v)
            i += 1
        }
        guard !values.isEmpty else {
            return "no numeric lines below — list a column of bare numbers"
        }
        let result: Double
        switch op {
        case "sum":
            result = values.reduce(0, +)
        case "mean", "avg", "average":
            result = values.reduce(0, +) / Double(values.count)
        case "median":
            result = listMedian(values)
        case "min":
            result = values.min() ?? 0
        case "max":
            result = values.max() ?? 0
        case "stddev", "stdev":
            result = listStdDev(values)
        default:
            return nil
        }
        return formatStat(result, count: values.count)
    }

    private static func listMedian(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let n = sorted.count
        if n % 2 == 0 { return (sorted[n/2 - 1] + sorted[n/2]) / 2 }
        return sorted[n/2]
    }

    private static func listStdDev(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count - 1)
        return sqrt(variance)
    }

    private static func formatStat(_ value: Double, count: Int) -> String {
        let p = UserDefaults.standard.object(forKey: "vektor.precision") as? Int ?? 2
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        nf.minimumFractionDigits = 0
        nf.maximumFractionDigits = max(0, min(14, p))
        nf.groupingSeparator = ","
        let formatted = nf.string(from: NSNumber(value: value)) ?? String(value)
        return "\(formatted)  (\(count) values)"
    }
}
