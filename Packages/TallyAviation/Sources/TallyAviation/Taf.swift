import Foundation

/// Decoded TAF (Terminal Aerodrome Forecast). The forecast is broken into
/// a sequence of forecast periods, each starting at a "from" time and ending
/// either at the start of the next period or at the TAF validity end.
public struct DecodedTaf: Equatable, Sendable {
    public let raw: String
    public let station: String?
    public let issuedAt: Date?
    public let validityStart: Date?
    public let validityEnd: Date?
    public let periods: [Period]

    public struct Period: Equatable, Sendable {
        public enum Kind: String, Sendable {
            case main             // initial forecast (no marker)
            case from             // FM010000
            case becoming         // BECMG 0100/0103
            case temporary        // TEMPO 0100/0103
            case probability30    // PROB30 0100/0103
            case probability40    // PROB40 0100/0103
        }

        public let kind: Kind
        public let startsAt: Date?
        public let endsAt: Date?
        public let probability: Int?     // 30 or 40 for PROBxx
        public let raw: String           // the raw token group, useful for display
        public let wind: DecodedMetar.Wind?
        public let visibility: DecodedMetar.Visibility?
        public let weather: [String]
        public let clouds: [DecodedMetar.Cloud]
    }
}

public enum TafParser {

    public static func parse(_ raw: String) -> DecodedTaf {
        // Collapse whitespace & newlines, drop trailing "=" terminator.
        var body = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "=", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while body.contains("  ") {
            body = body.replacingOccurrences(of: "  ", with: " ")
        }

        var tokens = body.split(separator: " ").map(String.init)
        if let first = tokens.first, ["TAF", "AMD", "COR"].contains(first) {
            tokens.removeFirst()
            // TAF AMD / TAF COR variants
            if let next = tokens.first, ["AMD", "COR"].contains(next) {
                tokens.removeFirst()
            }
        }

        var station: String? = nil
        var issuedAt: Date? = nil
        var validityStart: Date? = nil
        var validityEnd: Date? = nil
        var i = 0

        if i < tokens.count, isICAOStation(tokens[i]) {
            station = tokens[i]; i += 1
        }
        if i < tokens.count, isIssuedTime(tokens[i]) {
            issuedAt = parseIssuedTime(tokens[i]); i += 1
        }
        if i < tokens.count, let (start, end) = parseValidity(tokens[i]) {
            validityStart = start; validityEnd = end; i += 1
        }

        // Split remaining tokens into periods.
        let remaining = Array(tokens[i...])
        var periods: [DecodedTaf.Period] = []

        var current: [String] = []
        var currentKind: DecodedTaf.Period.Kind = .main
        var currentStart: Date? = validityStart
        var currentEnd: Date? = validityEnd
        var currentProb: Int? = nil

        func flush() {
            guard !current.isEmpty else { return }
            let group = parsePeriodFields(tokens: current)
            periods.append(.init(
                kind: currentKind,
                startsAt: currentStart,
                endsAt: currentEnd,
                probability: currentProb,
                raw: current.joined(separator: " "),
                wind: group.wind,
                visibility: group.visibility,
                weather: group.weather,
                clouds: group.clouds
            ))
        }

        var j = 0
        while j < remaining.count {
            let t = remaining[j]
            // FM<DDHHMM>
            if t.hasPrefix("FM") && t.count == 8, let d = parseFromTime(t) {
                // Chain the previous period's end to this FM's start so each
                // FM segment reports the correct window. Without this every
                // FM period inherited `validityEnd` and produced overlapping
                // windows ending at the TAF's validity end.
                if currentKind == .main || currentKind == .from {
                    currentEnd = d
                }
                flush()
                current = []
                currentKind = .from
                currentStart = d
                currentEnd = validityEnd
                currentProb = nil
                j += 1
                continue
            }
            // BECMG / TEMPO + <DDHH/DDHH>
            if (t == "BECMG" || t == "TEMPO") && j + 1 < remaining.count,
               let (s, e) = parsePeriodRange(remaining[j + 1])
            {
                flush()
                current = []
                currentKind = (t == "BECMG") ? .becoming : .temporary
                currentStart = s
                currentEnd = e
                currentProb = nil
                j += 2
                continue
            }
            // PROB30 / PROB40 [TEMPO] + range
            if (t == "PROB30" || t == "PROB40") {
                flush()
                current = []
                currentProb = (t == "PROB30") ? 30 : 40
                currentKind = (t == "PROB30") ? .probability30 : .probability40
                j += 1
                if j < remaining.count && remaining[j] == "TEMPO" {
                    j += 1
                }
                if j < remaining.count, let (s, e) = parsePeriodRange(remaining[j]) {
                    currentStart = s; currentEnd = e; j += 1
                }
                continue
            }
            current.append(t)
            j += 1
        }
        flush()

        return DecodedTaf(
            raw: raw,
            station: station,
            issuedAt: issuedAt,
            validityStart: validityStart,
            validityEnd: validityEnd,
            periods: periods
        )
    }

    // MARK: - Token helpers

    private static func isICAOStation(_ s: String) -> Bool {
        s.count == 4 && s.allSatisfy { $0.isLetter && $0.isUppercase }
    }

    private static func isIssuedTime(_ s: String) -> Bool {
        s.count == 7 && s.hasSuffix("Z") && s.dropLast().allSatisfy(\.isNumber)
    }

    private static func parseIssuedTime(_ s: String) -> Date? {
        let body = String(s.dropLast())
        guard body.count == 6,
              let day = Int(body.prefix(2)),
              let hour = Int(body.dropFirst(2).prefix(2)),
              let min = Int(body.dropFirst(4)) else { return nil }
        return calendarDate(day: day, hour: hour, minute: min)
    }

    /// "0212/0312" → start 02@12Z, end 03@12Z (same month as today, UTC).
    private static func parseValidity(_ s: String) -> (Date, Date)? {
        guard s.count == 9, s[s.index(s.startIndex, offsetBy: 4)] == "/" else { return nil }
        let lhs = String(s.prefix(4)); let rhs = String(s.suffix(4))
        guard let s1 = parseDayHour(lhs), let s2 = parseDayHour(rhs) else { return nil }
        return (s1, s2)
    }

    private static func parsePeriodRange(_ s: String) -> (Date, Date)? {
        parseValidity(s)
    }

    private static func parseDayHour(_ s: String) -> Date? {
        guard s.count == 4, let day = Int(s.prefix(2)), let hour = Int(s.suffix(2)) else { return nil }
        // 24Z = next day, 00Z
        let h = hour == 24 ? 0 : hour
        let d = hour == 24 ? day + 1 : day
        return calendarDate(day: d, hour: h, minute: 0)
    }

    private static func parseFromTime(_ s: String) -> Date? {
        guard s.hasPrefix("FM"), s.count == 8 else { return nil }
        let body = String(s.dropFirst(2))
        guard let day = Int(body.prefix(2)),
              let hour = Int(body.dropFirst(2).prefix(2)),
              let min = Int(body.dropFirst(4)) else { return nil }
        return calendarDate(day: day, hour: hour, minute: min)
    }

    private static func calendarDate(day: Int, hour: Int, minute: Int) -> Date? {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!
        let now = Date()
        var comps = c.dateComponents([.year, .month], from: now)
        comps.day = day; comps.hour = hour; comps.minute = minute; comps.second = 0
        return c.date(from: comps)
    }

    // MARK: - Period fields (re-use METAR field detectors)

    private struct Group {
        let wind: DecodedMetar.Wind?
        let visibility: DecodedMetar.Visibility?
        let weather: [String]
        let clouds: [DecodedMetar.Cloud]
    }

    private static func parsePeriodFields(tokens: [String]) -> Group {
        var wind: DecodedMetar.Wind?
        var visibility: DecodedMetar.Visibility?
        var weather: [String] = []
        var clouds: [DecodedMetar.Cloud] = []

        var idx = 0
        let workingTokens = tokens
        while idx < workingTokens.count {
            let t = workingTokens[idx]
            defer { idx += 1 }

            if wind == nil, let w = MetarParser.publicParseWind(t) {
                wind = w; continue
            }
            if visibility == nil, let v = MetarParser.publicParseVisibility(t, allTokens: workingTokens, currentIndex: &idx) {
                visibility = v; continue
            }
            if MetarParser.publicIsWeather(t) { weather.append(t); continue }
            if let c = MetarParser.publicParseCloud(t) { clouds.append(c); continue }
        }

        return Group(wind: wind, visibility: visibility, weather: weather, clouds: clouds)
    }
}
