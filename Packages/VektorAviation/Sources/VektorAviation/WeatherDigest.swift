import Foundation

/// Turns aviation METAR + TAF into a plain-language weather summary for
/// non-pilots. The METAR supplies "now" (temperature, conditions, wind);
/// the TAF supplies the "outlook" — but a TAF isn't a timeline, it's a set
/// of overlapping change rules (FM / BECMG / TEMPO / PROB) in Zulu time.
///
/// This type **flattens** those rules into a local-time series of *outcomes*
/// and phrases only what changes, so the reader never sees the aviation
/// grammar. It is intentionally pure (Foundation only, `now`/`timeZone`
/// injected) so the phrasing can be unit-tested deterministically.
///
/// Two semantics that matter for correctness:
///  * **Inheritance** — a BECMG group lists only what changes, so unspecified
///    fields (sky, weather, wind) carry forward from the prevailing state. An
///    FM group is a full reset.
///  * **Honest scope** — a TAF forecasts *conditions* (rain, sky, wind,
///    visibility), not temperature; the outlook is qualitative and only "now"
///    carries a temperature.
public struct WeatherDigest: Equatable, Sendable {

    public struct HourSlice: Equatable, Sendable {
        public let label: String   // localized clock, e.g. "6 PM" / "18"
        public let emoji: String   // weather glyph
        public let detail: String  // short word, e.g. "showers"
        public let isChance: Bool  // true when from a TEMPO/PROB overlay
    }

    /// Display name set by the caller, e.g. "Munich (EDDM)".
    public let place: String
    /// One-line current conditions, e.g. "18°C · partly cloudy · wind 22 km/h W".
    public let nowLine: String
    public let nowEmoji: String
    /// Plain-language outlook sentences (already time-of-day phrased).
    public let outlook: [String]
    /// Compact next-hours strip (may be empty if no usable TAF).
    public let hours: [HourSlice]
    public let hasForecast: Bool

    // MARK: - Build

    public static func make(place: String,
                            metar: DecodedMetar?,
                            taf: DecodedTaf?,
                            timeZone: TimeZone,
                            now: Date) -> WeatherDigest {
        let nowEmoji: String
        let nowLine: String
        if let m = metar {
            let night = isNight(now, timeZone)
            let cond = condition(weather: m.weather, clouds: m.clouds, night: night)
            nowEmoji = cond.emoji
            var parts: [String] = []
            if let t = m.temperatureC { parts.append("\(Int(t.rounded()))°C") }
            parts.append(cond.text)
            if let w = windText(m.wind) { parts.append(w) }
            nowLine = parts.joined(separator: " · ")
        } else {
            nowEmoji = "•"
            nowLine = "current conditions unavailable"
        }

        var hours: [HourSlice] = []
        var outlook: [String] = []
        var hasForecast = false

        if let taf, !taf.periods.isEmpty {
            let tl = Timeline(periods: taf.periods, validityEnd: taf.validityEnd)
            hours = buildHours(tl, from: now, timeZone: timeZone)
            outlook = buildOutlook(tl, metar: metar, from: now, timeZone: timeZone)
            hasForecast = !hours.isEmpty || !outlook.isEmpty
        }

        return WeatherDigest(place: place, nowLine: nowLine, nowEmoji: nowEmoji,
                             outlook: outlook, hours: hours, hasForecast: hasForecast)
    }

    // MARK: - Flattened timeline

    /// A fully-resolved set of conditions at an instant (after inheritance).
    struct State: Equatable {
        var weather: [String]
        var clouds: [DecodedMetar.Cloud]
        var wind: DecodedMetar.Wind?
        var visibility: DecodedMetar.Visibility?
    }

    /// Splits the TAF into a *prevailing* track (main / FM / BECMG — the
    /// definite forecast, with BECMG inheriting unspecified fields) and
    /// *overlay* caveats (TEMPO / PROB — temporary or probabilistic, used
    /// as-is). `prevailing(at:)` resolves the established state at any instant.
    struct Timeline {
        struct Seg { let at: Date; let state: State }
        let prevailing: [Seg]
        let overlays: [DecodedTaf.Period]
        let validityEnd: Date?

        init(periods: [DecodedTaf.Period], validityEnd: Date?) {
            self.validityEnd = validityEnd
            var segs: [Seg] = []
            var overlays: [DecodedTaf.Period] = []
            var running = State(weather: [], clouds: [], wind: nil, visibility: nil)
            for p in periods {
                switch p.kind {
                case .main, .from:
                    running = State.reset(from: p)        // full picture
                    if let t = p.startsAt { segs.append(Seg(at: t, state: running)) }
                case .becoming:
                    running = running.merging(p)          // inherit + override
                    if let t = p.endsAt ?? p.startsAt { segs.append(Seg(at: t, state: running)) }
                case .temporary, .probability30, .probability40:
                    overlays.append(p)
                }
            }
            self.prevailing = segs.sorted { $0.at < $1.at }
            self.overlays = overlays
        }

        func state(at t: Date) -> State? {
            var hit: State?
            for s in prevailing where s.at <= t { hit = s.state }
            return hit ?? prevailing.first?.state
        }
    }

    private static func buildHours(_ tl: Timeline, from now: Date,
                                   timeZone: TimeZone) -> [HourSlice] {
        let horizonCap = now.addingTimeInterval(18 * 3600)
        let horizon = min(tl.validityEnd ?? horizonCap, horizonCap)
        guard horizon > now else { return [] }

        // The strip shows the *prevailing* (definite) track only — the
        // honest baseline. TEMPO/PROB caveats ("chance of storms") are carried
        // by the outlook sentences instead, so a 30%-chance hour never gets a
        // scary icon implying certainty.
        let fmt = clockFormatter(timeZone)
        var slices: [HourSlice] = []
        var t = now.addingTimeInterval(2 * 3600)
        while t <= horizon && slices.count < 6 {
            let night = isNight(t, timeZone)
            let cond = tl.state(at: t).map {
                condition(weather: $0.weather, clouds: $0.clouds, night: night)
            } ?? Cond(text: "—", emoji: "•", rank: 0)
            slices.append(.init(label: fmt.string(from: t), emoji: cond.emoji,
                                detail: cond.text, isChance: false))
            t = t.addingTimeInterval(3 * 3600)
        }
        return slices
    }

    private static func buildOutlook(_ tl: Timeline, metar: DecodedMetar?,
                                     from now: Date, timeZone: TimeZone) -> [String] {
        var lines: [String] = []

        // 1) Prevailing changes after "now": clearing / clouding over / precip
        //    moving in / wind picking up. Compare each established segment to
        //    the one before it.
        var prevCond: Cond? = metar.map {
            condition(weather: $0.weather, clouds: $0.clouds, night: isNight(now, timeZone))
        }
        var prevWind: DecodedMetar.Wind? = metar?.wind
        for seg in tl.prevailing where seg.at > now {
            let night = isNight(seg.at, timeZone)
            let c = condition(weather: seg.state.weather, clouds: seg.state.clouds, night: night)
            let when = bucket(seg.at, from: now, timeZone: timeZone).capitalizedFirst
            if let phrase = transitionPhrase(from: prevCond, to: c) {
                lines.append("\(when) — \(phrase)")
            } else if let wphrase = windPhrase(from: prevWind, to: seg.state.wind) {
                lines.append("\(when) — \(wphrase)")
            }
            prevCond = c
            prevWind = seg.state.wind
        }

        // 2) Significant overlays (showers / storms / fog) as caveats.
        for p in tl.overlays {
            guard let s = p.startsAt, s >= now.addingTimeInterval(-3600) else { continue }
            let c = condition(weather: p.weather, clouds: p.clouds, night: isNight(s, timeZone))
            guard c.rank >= 3 else { continue }
            lines.append("\(bucket(s, from: now, timeZone: timeZone).capitalizedFirst) — \(chanceWord(for: p.kind)) \(c.text)")
        }

        var seen = Set<String>()
        var out: [String] = []
        for l in lines where seen.insert(l).inserted { out.append(l) }
        out = Array(out.prefix(4))

        if out.isEmpty, let c = prevCond {
            out = ["Staying \(c.text) for the next while."]
        }
        return out
    }

    private static func transitionPhrase(from: Cond?, to: Cond) -> String? {
        guard let from else { return to.rank >= 3 ? "\(to.text) moving in" : nil }
        if from.rank >= 3 && to.rank < 2 { return "\(to.text), clearing up" }
        if to.rank >= 4 && to.rank > from.rank { return "\(to.text) moving in" }
        if to.rank >= 2 && from.rank <= 1 && to.rank > from.rank { return "turning \(to.text)" }
        if to.rank <= 1 && from.rank >= 2 { return "clearing" }
        return nil
    }

    /// Phrase a notable wind change (gusts appearing, a big speed jump, or a
    /// large direction shift). Returns nil for minor changes.
    private static func windPhrase(from: DecodedMetar.Wind?, to: DecodedMetar.Wind?) -> String? {
        guard let to else { return nil }
        let oldSpeed = from?.speedKt ?? 0
        let gustNew = to.gustKt != nil && from?.gustKt == nil
        if gustNew || to.speedKt - oldSpeed >= 10 {
            if let d = to.fromDeg, !to.isVariable { return "wind picking up, turning \(compass(d))" }
            return "wind picking up"
        }
        if let dNew = to.fromDeg, let dOld = from?.fromDeg,
           angularDelta(dOld, dNew) >= 90, to.speedKt >= 10 {
            return "wind turning \(compass(dNew))"
        }
        return nil
    }

    private static func angularDelta(_ a: Int, _ b: Int) -> Int {
        let d = abs((a - b) % 360)
        return min(d, 360 - d)
    }

    private static func chanceWord(for kind: DecodedTaf.Period.Kind) -> String {
        switch kind {
        case .temporary:     return "chance of"
        case .probability30: return "small chance of"
        case .probability40: return "chance of"
        default:             return "possible"
        }
    }

    // MARK: - Condition model

    struct Cond: Equatable { let text: String; let emoji: String; let rank: Int }

    static func condition(weather: [String], clouds: [DecodedMetar.Cloud], night: Bool) -> Cond {
        var best: Cond?
        for raw in weather {
            let c = phenomenon(raw)
            if best == nil || c.rank > best!.rank { best = c }
        }
        if clouds.contains(where: { $0.type == "CB" || $0.type == "TCU" }) {
            let c = Cond(text: "storms", emoji: "⛈️", rank: 6)
            if best == nil || c.rank > best!.rank { best = c }
        }
        if let b = best, b.rank >= 3 { return b }
        let cover = dominantCloud(clouds, night: night)
        if let b = best, b.rank > cover.rank { return b }
        return cover
    }

    static func phenomenon(_ token: String) -> Cond {
        var t = token.uppercased()
        var intensity = 0
        if t.hasPrefix("+") { intensity = 1; t.removeFirst() }
        else if t.hasPrefix("-") { intensity = -1; t.removeFirst() }
        if t.hasPrefix("VC") { t.removeFirst(2) }

        if t.contains("TS") {
            return Cond(text: intensity > 0 ? "heavy thunderstorms" : "thunderstorms", emoji: "⛈️", rank: 6)
        }
        if t.contains("FZ") {
            return Cond(text: "freezing " + (t.contains("DZ") ? "drizzle" : "rain"), emoji: "🌨️", rank: 6)
        }
        if t.contains("SN") {
            return Cond(text: intensity > 0 ? "heavy snow" : intensity < 0 ? "light snow" : "snow", emoji: "🌨️", rank: 5)
        }
        if t.contains("GR") || t.contains("GS") { return Cond(text: "hail", emoji: "🌨️", rank: 5) }
        if t.contains("RA") || t.contains("DZ") {
            let showers = t.contains("SH")
            let base = t.contains("DZ") ? "drizzle" : (showers ? "showers" : "rain")
            let w = (intensity > 0 ? "heavy " : intensity < 0 ? "light " : "") + base
            return Cond(text: w, emoji: showers ? "🌦️" : "🌧️", rank: 4)
        }
        if t.contains("FG") { return Cond(text: "fog", emoji: "🌫️", rank: 3) }
        if t.contains("BR") { return Cond(text: "mist", emoji: "🌫️", rank: 3) }
        if t.contains("HZ") { return Cond(text: "haze", emoji: "🌫️", rank: 3) }
        if t.contains("FU") { return Cond(text: "smoke", emoji: "🌫️", rank: 3) }
        return Cond(text: "unsettled", emoji: "🌥️", rank: 2)
    }

    static func dominantCloud(_ clouds: [DecodedMetar.Cloud], night: Bool) -> Cond {
        let clear = Cond(text: "clear", emoji: night ? "🌙" : "☀️", rank: 0)
        func rankOf(_ c: DecodedMetar.Cloud.Cover) -> Int {
            switch c {
            case .overcast: return 4
            case .broken:   return 3
            case .scattered: return 2
            case .few:      return 1
            default:        return 0
            }
        }
        guard let top = clouds.max(by: { rankOf($0.cover) < rankOf($1.cover) }) else { return clear }
        switch top.cover {
        case .overcast:  return Cond(text: "overcast", emoji: "☁️", rank: 2)
        case .broken:    return Cond(text: "cloudy", emoji: "☁️", rank: 2)
        case .scattered: return Cond(text: "partly cloudy", emoji: night ? "☁️" : "🌤️", rank: 1)
        case .few:       return Cond(text: "a few clouds", emoji: night ? "🌙" : "🌤️", rank: 1)
        default:         return clear
        }
    }

    // MARK: - Wind / compass

    static func windText(_ w: DecodedMetar.Wind?) -> String? {
        guard let w else { return nil }
        let kmh = Int((Double(w.speedKt) * 1.852).rounded())
        if kmh < 8 && w.gustKt == nil { return "light wind" }
        var s = "wind \(kmh) km/h"
        if let dir = w.fromDeg, !w.isVariable { s += " \(compass(dir))" }
        if let g = w.gustKt { s += " (gusts \(Int((Double(g) * 1.852).rounded())))" }
        return s
    }

    static func compass(_ deg: Int) -> String {
        let dirs = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        return dirs[Int((Double((deg % 360 + 360) % 360) / 45).rounded()) % 8]
    }

    // MARK: - Time-of-day phrasing

    static func bucket(_ date: Date, from now: Date, timeZone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let dayDiff = cal.dateComponents([.day],
                                         from: cal.startOfDay(for: now),
                                         to: cal.startOfDay(for: date)).day ?? 0
        let hour = cal.component(.hour, from: date)

        func partOfDay() -> String {
            switch hour {
            case 5..<12:  return "morning"
            case 12..<17: return "afternoon"
            case 17..<21: return "evening"
            default:      return "night"
            }
        }

        if dayDiff <= 0 {
            switch hour {
            case 5..<12:  return "this morning"
            case 12..<17: return "this afternoon"
            case 17..<21: return "this evening"
            default:      return "tonight"
            }
        }
        if dayDiff == 1 { return hour < 5 ? "late tonight" : "tomorrow \(partOfDay())" }
        let wd = DateFormatter()
        wd.locale = Locale(identifier: "en_US_POSIX")
        wd.timeZone = timeZone
        wd.dateFormat = "EEEE"
        return wd.string(from: date)
    }

    static func clockFormatter(_ timeZone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.timeZone = timeZone
        f.locale = .autoupdatingCurrent
        f.setLocalizedDateFormatFromTemplate("j")
        return f
    }

    static func isNight(_ date: Date, _ timeZone: TimeZone) -> Bool {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let h = cal.component(.hour, from: date)
        return h < 6 || h >= 21
    }
}

extension WeatherDigest.State {
    /// A full-picture reset (main / FM). CAVOK implies clear sky + good vis.
    static func reset(from p: DecodedTaf.Period) -> WeatherDigest.State {
        var s = WeatherDigest.State(weather: p.weather, clouds: p.clouds,
                                    wind: p.wind, visibility: p.visibility)
        if p.visibility?.isCAVOK == true { s.clouds = []; s.weather = [] }
        return s
    }

    /// A BECMG merge: override only the fields the group specifies, inherit
    /// the rest. CAVOK clears sky + weather.
    func merging(_ p: DecodedTaf.Period) -> WeatherDigest.State {
        var s = self
        if let w = p.wind { s.wind = w }
        if !p.clouds.isEmpty { s.clouds = p.clouds }
        if !p.weather.isEmpty { s.weather = p.weather }
        if let v = p.visibility {
            s.visibility = v
            if v.isCAVOK { s.clouds = []; s.weather = [] }
        }
        return s
    }
}

private extension String {
    var capitalizedFirst: String {
        guard let f = first else { return self }
        return f.uppercased() + dropFirst()
    }
}
