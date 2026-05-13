import SwiftUI
import TallyAviation
import TallyEngine

struct MetarView: View {
    @State private var icao: String = "KSFO"
    @State private var metarRaw: String = ""
    @State private var tafRaw: String = ""
    @State private var decodedMetar: DecodedMetar?
    @State private var decodedTaf: DecodedTaf?
    @State private var loading = false
    @State private var error: String?
    @State private var runwayId: String = "28L"
    @State private var fetchTask: Task<Void, Never>? = nil
    @State private var metarFetchedAt: Date?
    @State private var tafFetchedAt: Date?
    @State private var clockTick = false   // re-renders "x minutes ago"

    /// Process-wide METAR service. Sharing one instance with
    /// `MetarCacheBridge` keeps the in-memory cache consistent and avoids
    /// two parallel actors racing to write the same disk file.
    private let service = MetarService.shared
    /// 30-second ticker — re-renders the "x minutes ago" timestamp only.
    private let clockTickTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    /// Five-minute ticker that drives the actual background re-fetch.
    /// Matches what the section footer copy promises. METAR re-fetches on
    /// every tick (5 min). TAF and ATIS use longer cadences enforced inside
    /// the re-fetch path.
    private let dataRefreshTimer = Timer.publish(every: 300, on: .main, in: .common).autoconnect()
    /// Per-kind staleness thresholds for the background re-fetch. METAR
    /// observations are issued every 30–60 min (with SPECI between), TAFs
    /// change a handful of times per day, ATIS letters tick ~hourly.
    private static let metarRefreshAfter: TimeInterval = 5 * 60       //  5 min
    private static let tafRefreshAfter:   TimeInterval = 30 * 60      // 30 min

    var body: some View {
        Form {
            Section {
                LabeledContent("ICAO") {
                    HStack(spacing: 8) {
                        TextField("", text: $icao, prompt: Text("EDDM"))
                            .textCase(.uppercase)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 160)
                            .labelsHidden()
                            .help("ICAO airport code, e.g. KSFO, EDDM, RJTT.")
                            .onChange(of: icao) { _, new in
                                let upper = new.uppercased()
                                if upper != new { icao = upper }
                            }
                        Button {
                            scheduleFetch(icao, immediate: true)
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Refresh METAR + TAF now")
                        .accessibilityLabel("Refresh weather")
                        .disabled(loading)
                    }
                }
                if loading {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Fetching METAR + TAF…").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let stamp = freshnessLine() {
                    Text(stamp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .id(clockTick) // forces re-render when the timer ticks
                }
                if let error {
                    HStack(spacing: 6) {
                        StatusBadge(level: .bad)
                        Text(error)
                    }
                    .font(.caption)
                    .foregroundStyle(StatusLevel.bad.colour)
                }
            } footer: {
                Text("Both METAR and TAF auto-fetch as soon as you've typed a 3–4 letter station code, then refresh in the background every 5 minutes. Click the refresh button to force an immediate fetch.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if !metarRaw.isEmpty {
                metarSections
            }
            if !tafRaw.isEmpty {
                tafSections
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(TallyTheme.background)
        .onChange(of: icao) { _, newValue in scheduleFetch(newValue) }
        .onAppear {
            scheduleFetch(icao, immediate: true)
        }
        .onReceive(clockTickTimer) { _ in clockTick.toggle() }
        .onReceive(dataRefreshTimer) { _ in autoRefreshIfStale() }
    }

    /// Fired by `dataRefreshTimer` every 5 minutes. Re-fetches METAR / TAF
    /// when their last fetch is older than the per-kind threshold.
    /// `scheduleFetch` cancels any in-flight fetch, so racing with a user-
    /// triggered fetch is safe.
    private func autoRefreshIfStale() {
        let (_, id) = parseQuery(icao)
        guard id.count >= 3 else { return }
        let now = Date()
        let metarStale = metarFetchedAt.map { now.timeIntervalSince($0) > Self.metarRefreshAfter } ?? true
        let tafStale   = tafFetchedAt.map   { now.timeIntervalSince($0) > Self.tafRefreshAfter   } ?? true
        guard metarStale || tafStale else { return }
        scheduleFetch(icao, immediate: true)
    }

    /// "METAR 09:07 · TAF 08:23" — only shows fields that have data.
    private func freshnessLine() -> String? {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "HH:mm"
        var parts: [String] = []
        if let m = metarFetchedAt { parts.append("METAR " + relativeOrTime(m, fmt: fmt)) }
        if let t = tafFetchedAt   { parts.append("TAF "   + relativeOrTime(t, fmt: fmt)) }
        return parts.isEmpty ? nil : "Last updated · " + parts.joined(separator: " · ")
    }

    private func relativeOrTime(_ date: Date, fmt: DateFormatter) -> String {
        let secondsAgo = Int(Date().timeIntervalSince(date))
        switch secondsAgo {
        case ..<60:     return "just now"
        case ..<3600:   return "\(secondsAgo / 60)m ago"
        default:        return fmt.string(from: date)
        }
    }

    // MARK: - METAR rendering

    @ViewBuilder
    private var metarSections: some View {
        Section("METAR") {
            Text(metarRaw)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
        }
        if let decoded = decodedMetar {
            Section("METAR decoded") {
                LabeledContent("Station", value: decoded.station ?? "—")
                if let observed = decoded.observedAt {
                    LabeledContent("Observed", value: observed.formatted(date: .numeric, time: .shortened))
                }
                if let wind = decoded.wind {
                    windRow(wind, severity: MetarDanger.severity(forWind: wind))
                }
                if let v = decoded.visibility {
                    visibilityRow(v, severity: MetarDanger.severity(forVisibility: v))
                }
                if !decoded.weather.isEmpty {
                    LabeledContent("Weather") {
                        Text(decoded.weather.joined(separator: " "))
                            .foregroundStyle(color(for: MetarDanger.severity(forWeather: decoded.weather)))
                    }
                }
                if !decoded.clouds.isEmpty {
                    LabeledContent("Clouds") {
                        Text(cloudsDescription(decoded.clouds))
                            .foregroundStyle(color(for: MetarDanger.severity(forCeiling: decoded.clouds)))
                    }
                }
                if let t = decoded.temperatureC, let d = decoded.dewpointC {
                    LabeledContent("Temp / Dewpoint", value: "\(Int(t))°C / \(Int(d))°C")
                }
                if let a = decoded.altimeter { altimeterRow(a) }
                if let r = decoded.remarks {
                    LabeledContent("Remarks", value: r)
                }
                if let trend = decoded.trend {
                    LabeledContent("Trend") {
                        Text(trend)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(TallyTheme.accent)
                            .help("ICAO trend forecast valid for the next 2 hours")
                    }
                }
            }

            if let wind = decoded.wind, let from = wind.fromDeg ?? wind.variableRange?.0 {
                Section("Runway crosswind") {
                    HStack {
                        TextField("Runway", text: $runwayId)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                        Spacer()
                    }
                    if let hdg = Runway.headingFromRunwayId(runwayId) {
                        let c = Runway.components(
                            runwayHeadingDeg: hdg,
                            windFromDeg: Double(from),
                            windSpeed: Double(wind.gustKt ?? wind.speedKt)
                        )
                        LabeledContent("Headwind",  value: String(format: "%+.0f kt", c.headwind))
                        LabeledContent("Crosswind", value: String(format: "%.0f kt %@", c.crosswind, c.crosswindFromRight ? "(R)" : "(L)"))
                    }
                }
            }
        }
    }

    // MARK: - TAF rendering

    @ViewBuilder
    private var tafSections: some View {
        Section("TAF") {
            Text(tafRaw)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
        }
        if let taf = decodedTaf {
            Section("TAF decoded") {
                LabeledContent("Station", value: taf.station ?? "—")
                if let v1 = taf.validityStart, let v2 = taf.validityEnd {
                    LabeledContent("Valid",
                                   value: "\(v1.formatted(date: .numeric, time: .shortened)) → \(v2.formatted(date: .numeric, time: .shortened))")
                }
            }
            ForEach(Array(taf.periods.enumerated()), id: \.offset) { _, p in
                Section(periodTitle(p)) {
                    if let w = p.wind { windRow(w) }
                    if let v = p.visibility { visibilityRow(v) }
                    if !p.weather.isEmpty {
                        LabeledContent("Weather", value: p.weather.joined(separator: " "))
                    }
                    if !p.clouds.isEmpty {
                        LabeledContent("Clouds", value: cloudsDescription(p.clouds))
                    }
                    Text(p.raw).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func periodTitle(_ p: DecodedTaf.Period) -> String {
        let kindLabel: String
        switch p.kind {
        case .main:           kindLabel = "Initial"
        case .from:           kindLabel = "From"
        case .becoming:       kindLabel = "Becoming"
        case .temporary:      kindLabel = "Temporary"
        case .probability30:  kindLabel = "30% chance"
        case .probability40:  kindLabel = "40% chance"
        }
        if let s = p.startsAt, let e = p.endsAt {
            return "\(kindLabel) · \(s.formatted(date: .omitted, time: .shortened))–\(e.formatted(date: .omitted, time: .shortened))"
        }
        if let s = p.startsAt {
            return "\(kindLabel) · from \(s.formatted(date: .omitted, time: .shortened))"
        }
        return kindLabel
    }

    // MARK: - Auto-fetch

    private func scheduleFetch(_ raw: String, immediate: Bool = false) {
        fetchTask?.cancel()
        let (_, id) = parseQuery(raw)
        guard id.count >= 3 else {
            error = nil; loading = false
            return
        }
        fetchTask = Task { @MainActor in
            if !immediate {
                try? await Task.sleep(for: .milliseconds(350))
                if Task.isCancelled { return }
            }
            loading = true; error = nil
            decodedMetar = nil; decodedTaf = nil
            metarRaw = ""; tafRaw = ""

            async let metarEntry = service.metar(for: id)
            async let tafEntry   = service.taf(for: id)
            let (m, t) = await (metarEntry, tafEntry)
            // If a newer keystroke cancelled this task while we were
            // awaiting the network, drop the result on the floor — without
            // this guard a stale fetch for "KSF" overwrites the UI right
            // after the user has typed "KSFO" and a new fetch is in flight.
            if Task.isCancelled { return }
            loading = false

            if let m, !m.raw.isEmpty {
                metarRaw = m.raw
                decodedMetar = MetarParser.parse(m.raw)
                metarFetchedAt = m.fetchedAt
            }
            if let t, !t.raw.isEmpty {
                tafRaw = t.raw
                decodedTaf = TafParser.parse(t.raw)
                tafFetchedAt = t.fetchedAt
            }
            if metarRaw.isEmpty && tafRaw.isEmpty {
                error = "No METAR/TAF found for \(id)."
            }
        }
    }

    /// Accept either "EDDM", "METAR EDDM", or "TAF EDDM" — the keyword is
    /// preserved but we always fetch both, so the keyword is informational only.
    private func parseQuery(_ raw: String) -> (MetarService.ReportKind, String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let tokens = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        if let first = tokens.first {
            if first == "METAR" { return (.metar, tokens.dropFirst().joined(separator: " ")) }
            if first == "TAF"   { return (.taf,   tokens.dropFirst().joined(separator: " ")) }
        }
        return (.metar, trimmed)
    }

    // MARK: - Field rows

    private func windRow(_ w: DecodedMetar.Wind, severity: MetarDanger.Severity = .ok) -> some View {
        let dir = w.isVariable ? "VRB" : "\(w.fromDeg ?? 0)°"
        let speed = "\(w.speedKt) kt"
        let gust = w.gustKt.map { ", gust \($0) kt" } ?? ""
        return LabeledContent("Wind") {
            Text("\(dir) @ \(speed)\(gust)")
                .foregroundStyle(color(for: severity))
        }
    }

    private func visibilityRow(_ v: DecodedMetar.Visibility, severity: MetarDanger.Severity = .ok) -> some View {
        let text: String
        if v.isCAVOK { text = "CAVOK" }
        else if let m = v.meters { text = "\(m) m" }
        else if let sm = v.statuteMiles { text = String(format: "%g SM", sm) }
        else { text = "—" }
        return LabeledContent("Visibility") {
            Text(text).foregroundStyle(color(for: severity))
        }
    }

    private func color(for severity: MetarDanger.Severity) -> Color {
        switch severity {
        case .ok:     return .primary
        case .warn:   return .orange
        case .danger: return .red
        }
    }

    private func cloudsDescription(_ clouds: [DecodedMetar.Cloud]) -> String {
        clouds.map { c in
            let alt = c.altitudeFt.map { " @ \($0) ft" } ?? ""
            let type = c.type.map { " \($0)" } ?? ""
            return "\(c.cover.rawValue)\(alt)\(type)"
        }.joined(separator: ", ")
    }

    private func altimeterRow(_ a: DecodedMetar.Altimeter) -> some View {
        if let inHg = a.inHg { return LabeledContent("Altimeter", value: String(format: "%.2f inHg", inHg)) }
        if let hPa = a.hPa { return LabeledContent("Altimeter", value: "\(Int(hPa)) hPa") }
        return LabeledContent("Altimeter", value: "—")
    }
}
