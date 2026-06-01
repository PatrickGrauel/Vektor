import SwiftUI
import VektorEngine
import VektorAviation

/// Live METAR + TAF for an ICAO, fetched from MetarService (aviationweather.gov)
/// and decoded with VektorAviation's parsers.
struct AvMetarView: View {
    @AppStorage("vektor.av.metar.icao") private var icao = "EDDM"
    @State private var metarRaw: String?
    @State private var tafRaw: String?
    @State private var observedAt: Date?
    @State private var loading = false
    @State private var didError = false

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("ICAO (e.g. EDDM)", text: $icao)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                        .onSubmit { Task { await load() } }
                    Button { Task { await load() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(loading)
                }
            }

            if loading {
                Section {
                    HStack(spacing: 10) { ProgressView(); Text("Fetching…").foregroundStyle(VektorTheme.muted) }
                }
            }

            if let metarRaw {
                Section("METAR") {
                    Text(metarRaw)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(VektorTheme.text)
                        .textSelection(.enabled)
                    decoded(MetarParser.parse(metarRaw))
                }
            }

            if let tafRaw {
                Section("TAF") {
                    Text(tafRaw)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(VektorTheme.text)
                        .textSelection(.enabled)
                }
            }

            if didError && metarRaw == nil && !loading {
                Section {
                    Text("Couldn't fetch weather for \(icao.uppercased()). Check the code and your connection.")
                        .font(.caption).foregroundStyle(VektorTheme.statusCaution)
                }
            }
        }
        .financeFormChrome("METAR / TAF")
        .task { await load() }
    }

    @ViewBuilder
    private func decoded(_ d: DecodedMetar) -> some View {
        if let w = d.wind {
            row("Wind", windText(w))
        }
        if let t = d.temperatureC {
            let dew = d.dewpointC.map { String(format: " / %.0f°", $0) } ?? ""
            row("Temp / Dewpoint", String(format: "%.0f°C", t) + dew)
        }
        if let obs = d.observedAt ?? observedAt {
            row("Observed", utc(obs))
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(VektorTheme.muted)
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(VektorTheme.text)
        }
        .font(.callout)
    }

    private func windText(_ w: DecodedMetar.Wind) -> String {
        let dir = w.isVariable ? "VRB" : String(format: "%03d°", w.fromDeg ?? 0)
        var s = "\(dir) @ \(w.speedKt) kt"
        if let g = w.gustKt { s += " G\(g)" }
        return s
    }

    private func utc(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "dd HH:mm'Z'"
        return f.string(from: date)
    }

    private func load() async {
        let code = icao.trimmingCharacters(in: .whitespaces).uppercased()
        guard !code.isEmpty else { return }
        loading = true
        didError = false
        defer { loading = false }
        async let m = MetarService.shared.metar(for: code)
        async let t = MetarService.shared.taf(for: code)
        let (mr, tr) = await (m, t)
        metarRaw = mr?.raw
        tafRaw = tr?.raw
        observedAt = mr?.fetchedAt
        if mr == nil { didError = true }
    }
}
