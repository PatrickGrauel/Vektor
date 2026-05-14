import Foundation

/// Hand-written METAR / TAF tokenizer + decoder.
///
/// Covers the core groups needed for pilot day-of-flight use: station,
/// observation time, wind (with variable / gusts), prevailing visibility,
/// runway visual range, weather phenomena, cloud layers, temperature /
/// dewpoint, and altimeter. Remarks (RMK …) are preserved as raw text.
public struct DecodedMetar: Equatable, Sendable {
    public let raw: String
    public let station: String?
    public let observedAt: Date?
    public let isAuto: Bool
    public let isCor: Bool
    public let wind: Wind?
    public let visibility: Visibility?
    public let weather: [String]
    public let clouds: [Cloud]
    public let temperatureC: Double?
    public let dewpointC: Double?
    public let altimeter: Altimeter?
    public let remarks: String?
    /// Trailing trend group: `NOSIG`, `TEMPO …`, or `BECMG …` (ICAO METAR
    /// only — US METARs omit it). Captured verbatim, including the leading
    /// keyword.
    public let trend: String?

    public struct Wind: Equatable, Sendable {
        public let fromDeg: Int?           // nil if variable (VRB)
        public let isVariable: Bool
        public let speedKt: Int
        public let gustKt: Int?
        public let variableRange: (Int, Int)?

        public static func == (lhs: Wind, rhs: Wind) -> Bool {
            lhs.fromDeg == rhs.fromDeg
                && lhs.isVariable == rhs.isVariable
                && lhs.speedKt == rhs.speedKt
                && lhs.gustKt == rhs.gustKt
                && lhs.variableRange?.0 == rhs.variableRange?.0
                && lhs.variableRange?.1 == rhs.variableRange?.1
        }
    }

    public struct Visibility: Equatable, Sendable {
        public let statuteMiles: Double?
        public let meters: Int?
        public let isCAVOK: Bool
    }

    public struct Cloud: Equatable, Sendable {
        public enum Cover: String, Sendable {
            case few = "FEW", scattered = "SCT", broken = "BKN", overcast = "OVC",
                 sky_clear = "SKC", clear = "CLR", no_significant = "NSC", no_clouds = "NCD",
                 vertical_visibility = "VV"
        }
        public let cover: Cover
        public let altitudeFt: Int?    // hundreds of feet × 100
        public let type: String?       // CB, TCU
    }

    public struct Altimeter: Equatable, Sendable {
        public let inHg: Double?       // e.g. 29.92
        public let hPa: Double?        // e.g. 1013
    }
}

public enum MetarParser {

    // MARK: - Public helpers re-used by TafParser

    public static func publicParseWind(_ s: String) -> DecodedMetar.Wind? { parseWind(s) }
    public static func publicParseVisibility(_ s: String, allTokens: [String], currentIndex: inout Int) -> DecodedMetar.Visibility? {
        parseVisibility(s, allTokens: allTokens, currentIndex: &currentIndex)
    }
    public static func publicIsWeather(_ s: String) -> Bool { isWeather(s) }
    public static func publicParseCloud(_ s: String) -> DecodedMetar.Cloud? { parseCloud(s) }

    public static func parse(_ raw: String) -> DecodedMetar {
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")

        // Split off remarks.
        var body = cleaned
        var remarks: String? = nil
        if let rmkRange = body.range(of: " RMK ") {
            remarks = String(body[rmkRange.upperBound...])
            body = String(body[..<rmkRange.lowerBound])
        }

        // Split off the TREND group (ICAO METAR landing forecast). Anchored
        // to whitespace + keyword to avoid catching e.g. a weather code that
        // happens to contain "BC" inside a bigger token.
        var trend: String? = nil
        for keyword in [" NOSIG", " TEMPO ", " BECMG "] {
            if let r = body.range(of: keyword) {
                let kw = keyword.trimmingCharacters(in: .whitespaces)
                let tail = String(body[r.lowerBound...]).trimmingCharacters(in: .whitespaces)
                trend = kw == "NOSIG" ? "NOSIG" : tail
                body = String(body[..<r.lowerBound])
                break
            }
        }

        var tokens = body.split(separator: " ").map(String.init)
        // Drop leading METAR/SPECI keyword if present.
        if let first = tokens.first, first == "METAR" || first == "SPECI" {
            tokens.removeFirst()
        }

        var station: String? = nil
        var observedAt: Date? = nil
        var isAuto = false
        var isCor = false
        var wind: DecodedMetar.Wind? = nil
        var visibility: DecodedMetar.Visibility? = nil
        var weather: [String] = []
        var clouds: [DecodedMetar.Cloud] = []
        var tempC: Double? = nil
        var dewC: Double? = nil
        var altimeter: DecodedMetar.Altimeter? = nil

        var i = 0
        while i < tokens.count {
            let t = tokens[i]; defer { i += 1 }

            if station == nil, isICAOStation(t) { station = t; continue }
            if observedAt == nil, isObservationTime(t) {
                observedAt = parseObservationTime(t); continue
            }
            if t == "AUTO" { isAuto = true; continue }
            if t == "COR" { isCor = true; continue }
            if wind == nil, let w = parseWind(t) {
                wind = w
                // Variable wind range (e.g. 250V310) often follows.
                if i + 1 < tokens.count, let range = parseVariableWindRange(tokens[i + 1]) {
                    wind = DecodedMetar.Wind(
                        fromDeg: w.fromDeg, isVariable: w.isVariable,
                        speedKt: w.speedKt, gustKt: w.gustKt, variableRange: range
                    )
                    i += 1
                }
                continue
            }
            if visibility == nil, let v = parseVisibility(t, allTokens: tokens, currentIndex: &i) {
                visibility = v
                continue
            }
            if isWeather(t) { weather.append(t); continue }
            if let c = parseCloud(t) { clouds.append(c); continue }
            if tempC == nil, let (t2, d2) = parseTempDew(t) {
                tempC = t2; dewC = d2; continue
            }
            if altimeter == nil, let a = parseAltimeter(t) { altimeter = a; continue }
        }

        return DecodedMetar(
            raw: raw, station: station, observedAt: observedAt,
            isAuto: isAuto, isCor: isCor,
            wind: wind, visibility: visibility,
            weather: weather, clouds: clouds,
            temperatureC: tempC, dewpointC: dewC,
            altimeter: altimeter, remarks: remarks,
            trend: trend
        )
    }

    // MARK: - Field detectors

    private static func isICAOStation(_ s: String) -> Bool {
        s.count == 4 && s.allSatisfy { $0.isLetter && $0.isUppercase }
    }

    private static func isObservationTime(_ s: String) -> Bool {
        s.count == 7 && s.hasSuffix("Z") && s.dropLast().allSatisfy(\.isNumber)
    }

    private static func parseObservationTime(_ s: String) -> Date? {
        let body = String(s.dropLast())
        guard body.count == 6,
              let day = Int(body.prefix(2)),
              let hour = Int(body.dropFirst(2).prefix(2)),
              let min = Int(body.dropFirst(4)) else { return nil }
        var c = Calendar(identifier: .gregorian)
        // Defensive: `TimeZone(identifier: "UTC")` never returns nil on
        // any supported platform, but falling back to `secondsFromGMT: 0`
        // keeps the parser off a force-unwrap.
        c.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0) ?? .current
        let now = Date()
        var comps = c.dateComponents([.year, .month], from: now)
        comps.day = day; comps.hour = hour; comps.minute = min; comps.second = 0
        return c.date(from: comps)
    }

    // MARK: - Wind

    private static func parseWind(_ s: String) -> DecodedMetar.Wind? {
        // dddffKT  dddffGggKT  VRBffKT
        guard s.hasSuffix("KT") || s.hasSuffix("MPS") || s.hasSuffix("KMH") else { return nil }
        let unit = s.hasSuffix("MPS") ? "MPS" : (s.hasSuffix("KMH") ? "KMH" : "KT")
        let core = String(s.dropLast(unit.count))
        guard core.count >= 5 else { return nil }

        let dirPart = String(core.prefix(3))
        let rest = String(core.dropFirst(3))

        let isVariable = (dirPart == "VRB")
        let fromDeg: Int? = isVariable ? nil : Int(dirPart)
        if !isVariable && fromDeg == nil { return nil }

        if let gIdx = rest.firstIndex(of: "G") {
            guard let speed = Int(rest[..<gIdx]),
                  let gust = Int(rest[rest.index(after: gIdx)...]) else { return nil }
            return DecodedMetar.Wind(fromDeg: fromDeg, isVariable: isVariable,
                                     speedKt: convertSpeedToKt(speed, unit: unit),
                                     gustKt: convertSpeedToKt(gust, unit: unit),
                                     variableRange: nil)
        } else {
            guard let speed = Int(rest) else { return nil }
            return DecodedMetar.Wind(fromDeg: fromDeg, isVariable: isVariable,
                                     speedKt: convertSpeedToKt(speed, unit: unit),
                                     gustKt: nil, variableRange: nil)
        }
    }

    private static func convertSpeedToKt(_ v: Int, unit: String) -> Int {
        switch unit {
        case "MPS": return Int((Double(v) * 1.9438).rounded())
        case "KMH": return Int((Double(v) * 0.5399568).rounded())
        default: return v
        }
    }

    private static func parseVariableWindRange(_ s: String) -> (Int, Int)? {
        guard s.count == 7, s[s.index(s.startIndex, offsetBy: 3)] == "V" else { return nil }
        let lhs = String(s.prefix(3))
        let rhs = String(s.suffix(3))
        guard let a = Int(lhs), let b = Int(rhs) else { return nil }
        return (a, b)
    }

    // MARK: - Visibility

    private static func parseVisibility(_ s: String, allTokens: [String], currentIndex: inout Int)
        -> DecodedMetar.Visibility?
    {
        if s == "CAVOK" {
            return .init(statuteMiles: nil, meters: nil, isCAVOK: true)
        }
        // Fraction form: "1 1/2SM" (two tokens) or "1/2SM"
        if s.hasSuffix("SM") {
            let core = String(s.dropLast(2))
            if let m = parseStatuteMiles(core) {
                return .init(statuteMiles: m, meters: nil, isCAVOK: false)
            }
        }
        // Whole number + next token "1/2SM"
        if Int(s) != nil,
           currentIndex + 1 < allTokens.count,
           allTokens[currentIndex + 1].hasSuffix("SM"),
           allTokens[currentIndex + 1].contains("/")
        {
            let nextCore = String(allTokens[currentIndex + 1].dropLast(2))
            if let whole = Double(s), let frac = parseStatuteMiles(nextCore) {
                currentIndex += 1
                return .init(statuteMiles: whole + frac, meters: nil, isCAVOK: false)
            }
        }
        // 4-digit meters (with optional NDV/D/N/E/W/S suffix)
        if s.count >= 4, let m = Int(s.prefix(4)) {
            let rest = s.dropFirst(4)
            if rest.isEmpty || rest == "NDV" || ["N","E","S","W","NE","NW","SE","SW"].contains(String(rest)) {
                return .init(statuteMiles: nil, meters: m, isCAVOK: false)
            }
        }
        return nil
    }

    private static func parseStatuteMiles(_ s: String) -> Double? {
        if let v = Double(s) { return v }
        let parts = s.split(separator: "/")
        if parts.count == 2, let num = Double(parts[0]), let den = Double(parts[1]), den != 0 {
            return num / den
        }
        return nil
    }

    // MARK: - Weather phenomena (rough match)

    private static func isWeather(_ s: String) -> Bool {
        // Intensity prefix
        let stripped = s.hasPrefix("-") || s.hasPrefix("+") ? String(s.dropFirst()) : s

        // Descriptor codes that, per ICAO Annex 3, MUST be followed by a
        // principal phenomenon code — they never stand alone. Without this
        // guard, a malformed METAR like `… VC 10SM …` would file the bare
        // "VC" as a weather phenomenon and the decoded view would lie.
        let descriptorsOnly: Set<String> = ["MI","PR","BC","DR","BL","SH","TS","FZ","VC"]
        let principals: Set<String> = ["RA","SN","DZ","GR","GS","FG","BR","HZ","FU","DU","SA","PL","SG","IC","DS","SS","PO","SQ","FC","UP"]
        let allCodes = descriptorsOnly.union(principals)

        // Token must be an even number of letters, ≥ 2.
        guard stripped.count >= 2, stripped.count % 2 == 0 else { return false }

        var sawPrincipal = false
        for i in stride(from: 0, to: stripped.count, by: 2) {
            let idx = stripped.index(stripped.startIndex, offsetBy: i)
            let endIdx = stripped.index(idx, offsetBy: 2, limitedBy: stripped.endIndex) ?? stripped.endIndex
            let pair = String(stripped[idx..<endIdx])
            if !allCodes.contains(pair) { return false }
            if principals.contains(pair) { sawPrincipal = true }
        }
        // TS (thunderstorm) and SH (showers) are listed as descriptors but
        // historically appear alone — accept TS by itself, reject the
        // others that genuinely never stand alone.
        if !sawPrincipal {
            return stripped == "TS"
        }
        return true
    }

    // MARK: - Clouds

    private static func parseCloud(_ s: String) -> DecodedMetar.Cloud? {
        let covers = ["FEW","SCT","BKN","OVC","SKC","CLR","NSC","NCD","VV"]
        for prefix in covers {
            if s.hasPrefix(prefix) {
                let rest = String(s.dropFirst(prefix.count))
                if rest.isEmpty {
                    return DecodedMetar.Cloud(cover: .init(rawValue: prefix) ?? .clear, altitudeFt: nil, type: nil)
                }
                // First 3 digits = hundreds of ft; trailing letters = type (CB/TCU)
                let heightChars = rest.prefix(while: { $0.isNumber })
                guard !heightChars.isEmpty, let hundreds = Int(heightChars) else { return nil }
                let type = String(rest.dropFirst(heightChars.count))
                return DecodedMetar.Cloud(
                    cover: DecodedMetar.Cloud.Cover(rawValue: prefix) ?? .clear,
                    altitudeFt: hundreds * 100,
                    type: type.isEmpty ? nil : type
                )
            }
        }
        return nil
    }

    // MARK: - Temperature / Dewpoint

    private static func parseTempDew(_ s: String) -> (Double, Double)? {
        guard let slash = s.firstIndex(of: "/") else { return nil }
        let lhs = String(s[..<slash])
        let rhs = String(s[s.index(after: slash)...])
        func parse(_ str: String) -> Double? {
            guard !str.isEmpty else { return nil }
            let neg = str.hasPrefix("M")
            let digits = neg ? String(str.dropFirst()) : str
            guard let v = Int(digits) else { return nil }
            return neg ? -Double(v) : Double(v)
        }
        guard let t = parse(lhs), let d = parse(rhs) else { return nil }
        return (t, d)
    }

    // MARK: - Altimeter

    private static func parseAltimeter(_ s: String) -> DecodedMetar.Altimeter? {
        if s.hasPrefix("A"), let v = Int(s.dropFirst()), s.count == 5 {
            return .init(inHg: Double(v) / 100.0, hPa: nil)
        }
        if s.hasPrefix("Q"), let v = Int(s.dropFirst()), s.count == 5 {
            return .init(inHg: nil, hPa: Double(v))
        }
        return nil
    }
}
