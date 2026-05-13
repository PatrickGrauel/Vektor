import Foundation
import JavaScriptCore

/// Resolves natural-language timezone phrases for the preprocessor and
/// performs date arithmetic. Implementation lives Swift-side so DST and
/// IANA tzdb stay correct via Foundation.
public struct TimezoneBridge {

    public init() {}

    /// Result of `nowString` / `convertTimeString`. `canonical` is `nil`
    /// unless the resolver normalised the input (e.g. "MUC" → "Munich").
    public struct Output: Sendable, Equatable {
        public let formatted: String
        public let canonical: String?
        public let originalCode: String?
    }

    /// Returns the current wall-clock time in the given timezone (plus an
    /// optional offset for `Zulu + 2` style arithmetic).
    public func nowString(in identifier: String, offsetSeconds: TimeInterval = 0) -> Output? {
        guard let resolved = resolveSync(identifier) else { return nil }
        guard let tz = TimeZone(identifier: resolved.timezoneId) else { return nil }
        let fmt = DateFormatter()
        fmt.timeZone = tz
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd HH:mm zzz"
        let date = Date().addingTimeInterval(offsetSeconds)
        let formatted = fmt.string(from: date)
        let canonicalHint = canonicalHint(for: identifier, resolved: resolved)
        return Output(formatted: formatted,
                      canonical: canonicalHint,
                      originalCode: resolved.originalCode)
    }

    /// Convert "HH:mm" / "h:mm a" from one zone to another (DST-aware) with
    /// an optional offset applied after the conversion.
    public func convertTimeString(_ time: String,
                                  from: String,
                                  to dest: String,
                                  on date: Date = Date(),
                                  offsetSeconds: TimeInterval = 0) -> Output? {
        guard let sourceResolved = resolveSync(from),
              let destResolved = resolveSync(dest),
              let sourceTZ = TimeZone(identifier: sourceResolved.timezoneId),
              let destTZ = TimeZone(identifier: destResolved.timezoneId) else { return nil }

        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = sourceTZ
        let candidates = ["HH:mm", "H:mm", "h:mm a", "ha", "h a", "HHmm"]
        var parsed: Date? = nil
        let normalisedTime = Self.normaliseMilitary(time)
        for f in candidates {
            parser.dateFormat = f
            if let d = parser.date(from: normalisedTime) {
                parsed = Self.alignToCalendarDay(d, base: date, in: sourceTZ); break
            }
        }
        guard let result = parsed else { return nil }
        let adjusted = result.addingTimeInterval(offsetSeconds)

        let fmt = DateFormatter()
        fmt.timeZone = destTZ
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "HH:mm zzz"
        let formatted = fmt.string(from: adjusted)
        let hint = canonicalHint(for: dest, resolved: destResolved)
        return Output(formatted: formatted,
                      canonical: hint,
                      originalCode: destResolved.originalCode)
    }

    // MARK: - Resolution (sync-only — async resolution kicks off from engine)

    /// Pull from the city resolver's synchronous cache, or fall back to the
    /// built-in IANA / aliases.
    ///
    /// For known-ambiguous codes (HKT, IST, CST, PST, BST, etc. — where the
    /// same letters are both an airport IATA code and a timezone abbreviation)
    /// the timezone abbreviation wins. Users typing "HKT" mean Hong Kong Time,
    /// not Phuket airport.
    public func resolveSync(_ raw: String) -> CityResolver.Resolved? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if Self.ambiguousAirportTzCodes.contains(key),
           let tz = legacyResolveLocal(raw) {
            return .init(canonicalName: raw.capitalized,
                         timezoneId: tz.identifier,
                         originalCode: nil)
        }
        if let cached = CityResolver.shared.cached(for: raw) { return cached }
        if let tz = legacyResolveLocal(raw) {
            return .init(canonicalName: raw.capitalized,
                         timezoneId: tz.identifier,
                         originalCode: nil)
        }
        return nil
    }

    /// Codes that mean different things as TZ abbreviation vs airport IATA.
    /// When the user types one of these, prefer the timezone interpretation.
    private static let ambiguousAirportTzCodes: Set<String> = [
        "HKT",  // TZ: Hong Kong, IATA: Phuket
        "IST",  // TZ: India / Israel / Istanbul, IATA: Istanbul SAW (rarely)
        "CST",  // TZ: US Central / China, not an IATA code
        "EST",  // TZ: US Eastern, not an IATA code
        "PST",  // TZ: US Pacific, not an IATA code
        "BST",  // TZ: British Summer, IATA: Brussels South Charleroi
        "MST",  // TZ: US Mountain, not an IATA code
        "ET", "PT", "MT", "CT",
    ]

    /// Legacy fallback: handles raw IANA identifiers and abbreviations
    /// (CET/PST/etc.) that CLGeocoder won't recognize.
    public func legacyResolveLocal(_ raw: String) -> TimeZone? {
        let cleaned = raw
            .replacingOccurrences(of: "time", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "in ", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespaces)
        if cleaned.isEmpty { return nil }
        if let id = Self.aliases[cleaned.uppercased()], let tz = TimeZone(identifier: id) { return tz }
        if let tz = TimeZone(identifier: cleaned) { return tz }
        if let tz = TimeZone(abbreviation: cleaned.uppercased()) { return tz }
        return nil
    }

    /// Legacy entry point used by tests + earlier call sites.
    public static func resolve(_ raw: String) -> TimeZone? {
        if let r = TimezoneBridge().resolveSync(raw),
           let tz = TimeZone(identifier: r.timezoneId) { return tz }
        return TimezoneBridge().legacyResolveLocal(raw)
    }

    // MARK: - Canonical-name hint formatting

    private func canonicalHint(for input: String,
                               resolved: CityResolver.Resolved) -> String? {
        let trimmed = input
            .replacingOccurrences(of: "time", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "in ", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // No hint needed if input is already the canonical name (case-insensitive)
        if trimmed.compare(resolved.canonicalName, options: .caseInsensitive) == .orderedSame {
            return nil
        }
        return resolved.canonicalName
    }

    // MARK: - Built-in IANA aliases

    private static let aliases: [String: String] = [
        "PST": "America/Los_Angeles", "PDT": "America/Los_Angeles", "PT": "America/Los_Angeles",
        "MST": "America/Denver", "MDT": "America/Denver",
        "CST": "America/Chicago", "CDT": "America/Chicago",
        "EST": "America/New_York", "EDT": "America/New_York", "ET": "America/New_York",
        "UTC": "UTC", "GMT": "Etc/GMT", "Z": "UTC", "ZULU": "UTC",
        "BST": "Europe/London", "WET": "Europe/Lisbon",
        "CET": "Europe/Berlin", "CEST": "Europe/Berlin",
        "EET": "Europe/Helsinki",
        "MSK": "Europe/Moscow",
        "IST": "Asia/Kolkata",
        "HKT": "Asia/Hong_Kong",
        "JST": "Asia/Tokyo", "KST": "Asia/Seoul",
        "SGT": "Asia/Singapore",
        "AEST": "Australia/Sydney", "AEDT": "Australia/Sydney",
        "AWST": "Australia/Perth",
        "WITA": "Asia/Makassar",
        "WIB": "Asia/Jakarta",
        "WIT": "Asia/Jayapura",
    ]

    /// Normalise 4-digit military time tokens ("1430", "0830") to a form
    /// the date parser recognises. Leaves anything else untouched.
    private static func normaliseMilitary(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.count == 4, trimmed.allSatisfy(\.isNumber) { return trimmed }
        return raw
    }

    /// Put the parsed time-of-day onto today's date in the source timezone.
    private static func alignToCalendarDay(_ time: Date, base: Date, in zone: TimeZone) -> Date {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = zone
        let dayComps = cal.dateComponents([.year, .month, .day], from: base)
        let timeComps = cal.dateComponents([.hour, .minute, .second], from: time)
        var merged = DateComponents()
        merged.year = dayComps.year; merged.month = dayComps.month; merged.day = dayComps.day
        merged.hour = timeComps.hour; merged.minute = timeComps.minute; merged.second = timeComps.second
        return cal.date(from: merged) ?? time
    }
}
