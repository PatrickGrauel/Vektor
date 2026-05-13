import Foundation

/// Surface-level pilot risk classification of weather observations.
/// Aviation rule-of-thumb thresholds, not authoritative. The classifier
/// covers the conditions a GA pilot scans for first.
public enum MetarDanger {
    public enum Severity: String, Sendable {
        case ok
        case warn        // worth noting (e.g. gusts 15–25 kt, BKN/OVC 1000-3000 ft)
        case danger      // proceed with caution / mins (TS, gusts > 25 kt, BKN<1000)
    }

    /// Wind danger: gusts above 20 kt = warn, > 25 kt = danger.
    public static func severity(forWind wind: DecodedMetar.Wind?) -> Severity {
        guard let wind else { return .ok }
        let gust = wind.gustKt ?? 0
        let speed = wind.speedKt
        if gust >= 25 || speed >= 30 { return .danger }
        if gust >= 20 || speed >= 25 { return .warn }
        return .ok
    }

    /// Visibility: < 3 SM (or < 5000 m) is warn; < 1 SM (< 1600 m) is danger.
    public static func severity(forVisibility v: DecodedMetar.Visibility?) -> Severity {
        guard let v else { return .ok }
        if v.isCAVOK { return .ok }
        if let sm = v.statuteMiles {
            if sm < 1 { return .danger }
            if sm < 3 { return .warn }
            return .ok
        }
        if let m = v.meters {
            if m < 1600 { return .danger }
            if m < 5000 { return .warn }
            return .ok
        }
        return .ok
    }

    /// Cloud ceiling: lowest BKN/OVC layer.
    /// Below 500 ft AGL = danger, below 1000 = warn (Class E VFR mins).
    public static func severity(forCeiling clouds: [DecodedMetar.Cloud]) -> Severity {
        var lowest: Int? = nil
        for c in clouds where c.cover == .broken || c.cover == .overcast || c.cover == .vertical_visibility {
            if let h = c.altitudeFt {
                lowest = min(lowest ?? Int.max, h)
            }
        }
        guard let ceiling = lowest else { return .ok }
        if ceiling < 500 { return .danger }
        if ceiling < 1000 { return .warn }
        return .ok
    }

    /// Weather phenomena codes that warrant a flag.
    /// TS (thunderstorm) anywhere is always danger. +RA, +SN, GR, FZRA are danger.
    /// -RA, BR, HZ, FG-without-CB are warn.
    public static func severity(forWeather codes: [String]) -> Severity {
        guard !codes.isEmpty else { return .ok }
        let joined = codes.joined(separator: " ")
        let dangerous = ["TS", "FC", "GR", "FZRA", "FZDZ", "VA", "DS", "SS", "+RA", "+SN", "+SHRA", "+TSRA"]
        for d in dangerous where joined.contains(d) { return .danger }
        if joined.contains("FG") || joined.contains("+") { return .warn }
        if joined.contains("BR") || joined.contains("HZ") || joined.contains("SN") || joined.contains("DZ") || joined.contains("RA") {
            return .warn
        }
        return .ok
    }

    /// Combined verdict — the worst severity from any axis.
    public static func overall(_ metar: DecodedMetar) -> Severity {
        let levels: [Severity] = [
            severity(forWind: metar.wind),
            severity(forVisibility: metar.visibility),
            severity(forCeiling: metar.clouds),
            severity(forWeather: metar.weather),
        ]
        if levels.contains(.danger) { return .danger }
        if levels.contains(.warn) { return .warn }
        return .ok
    }
}
