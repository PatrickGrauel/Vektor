import SwiftUI

/// Read-only quick-reference of every supported input pattern. Surfaced
/// from the calculator chrome and via ⌘? globally. Discovery-oriented:
/// the user wonders "wait, can it do X?" — this answers without making
/// them search docs or read the seed pages.
///
/// Sections are deliberately ordered breadth-first across feature areas
/// (math → units → money → time → dates → aviation → syntax → shortcuts)
/// so a top-to-bottom scroll surfaces the range of capabilities.
struct CheatsheetView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var search: String = ""

    private struct Entry: Identifiable {
        let example: String
        let detail: String
        var id: String { example }
    }

    private struct Section: Identifiable {
        let title: String
        let entries: [Entry]
        var id: String { title }
    }

    private static let sections: [Section] = [
        Section(title: "Math", entries: [
            Entry(example: "2 + 2",                                    detail: "Plain arithmetic"),
            Entry(example: "8 * (3.5 + 1)",                            detail: "Parentheses + order of ops"),
            Entry(example: "sqrt(2)",                                  detail: "Functions: sqrt, sin, cos, log, exp, …"),
            Entry(example: "sin(45°) ^ 2 + cos(45°) ^ 2",              detail: "Degrees with ° or radians"),
            Entry(example: "25% of 80",                                detail: "Percent of a value"),
            Entry(example: "prev * 12",                                detail: "`prev` = last evaluated result"),
            Entry(example: "rent = 1450 EUR",                          detail: "Variables — name a value, reuse it (case-insensitive)"),
        ]),
        Section(title: "Finance", entries: [
            Entry(example: "mortgage 250000 EUR at 3.4% for 25 years", detail: "Monthly payment · lifetime interest · total"),
            Entry(example: "compound 10000 EUR at 7% for 30 years",    detail: "Future value · growth · multiple"),
            Entry(example: "compound 100 at 5% for 10 years",          detail: "Currency optional"),
        ]),
        Section(title: "List statistics", entries: [
            Entry(example: "sum of:",                                  detail: "Aggregates the bare-numeric lines directly below"),
            Entry(example: "mean of:",                                 detail: "Average · also `avg`, `average`"),
            Entry(example: "median of:",                               detail: "Middle value"),
            Entry(example: "min of:  ·  max of:",                      detail: "Extremes"),
            Entry(example: "stddev of:",                               detail: "Sample standard deviation"),
            Entry(example: "sum",                                      detail: "On its own line: totals the values above, back to the last blank line · `total` / `average` / `avg` too · `sum in EUR` sets the unit"),
        ]),
        Section(title: "Units", entries: [
            Entry(example: "10 mi in km",                              detail: "`in` or `to` between any two units"),
            Entry(example: "120 kt in km/h",                           detail: "Speed"),
            Entry(example: "60000 ft in m",                            detail: "Length"),
            Entry(example: "180 lbs in kg",                            detail: "Mass"),
            Entry(example: "100°F in °C",                              detail: "Temperature"),
            Entry(example: "29.92 inHg in hPa",                        detail: "Pressure"),
            Entry(example: "2 hours in seconds",                       detail: "Time"),
            Entry(example: "5400 W * 3 hours in kWh",                  detail: "Mixed-unit arithmetic"),
            Entry(example: "(5 km + 800 m) in miles",                  detail: "Combine before converting"),
        ]),
        Section(title: "Money", entries: [
            Entry(example: "100 EUR in USD",                           detail: "Live FX (ECB rates, no key needed)"),
            Entry(example: "2500 USD in JPY",                          detail: "Any pair Vektor recognises"),
            Entry(example: "1 BTC in USD",                             detail: "Crypto — same syntax"),
            Entry(example: "0.5 ETH in EUR",                           detail: ""),
            Entry(example: "stock AAPL",                               detail: "Single quote (needs FMP key — Settings → Stocks)"),
        ]),
        Section(title: "Time", entries: [
            Entry(example: "Berlin time",                              detail: "Current time in a named city"),
            Entry(example: "SFO time",                                 detail: "IATA airport codes work"),
            Entry(example: "EDDM time",                                detail: "ICAO codes work"),
            Entry(example: "1430 Zulu in HKT",                         detail: "Zulu → local conversion"),
            Entry(example: "16:30 Bali time in Munich",                detail: "24-hour"),
            Entry(example: "4.30pm Uluwatu time in Barcelona",         detail: "European decimal + glued am/pm"),
            Entry(example: "now in Tokyo + 2h",                        detail: "Add a duration"),
            Entry(example: "9am tomorrow Berlin in Los Angeles",       detail: "Future date + zone"),
            Entry(example: "77/55 in hours",                           detail: "Duration from a quotient (h/min)"),
            Entry(example: "3725 in seconds",                          detail: "h/min/sec breakdown"),
        ]),
        Section(title: "Dates", entries: [
            Entry(example: "today",                                    detail: "ISO date for today"),
            Entry(example: "days between today and 2027-01-01",        detail: "Calendar-days difference"),
            Entry(example: "business days between today and 2027-01-01", detail: "Mon–Fri only (Sat/Sun excluded)"),
            Entry(example: "age 1990-03-15",                           detail: "Age in years right now"),
            Entry(example: "weekday 2027-07-04",                       detail: "Which day of the week"),
            Entry(example: "days between today and 2027-01-01 in weeks", detail: "Convert difference to other units"),
        ]),
        Section(title: "Aviation", entries: [
            Entry(example: "METAR EDDM",                               detail: "Live METAR + best-runway-by-wind"),
            Entry(example: "TAF KSFO",                                 detail: "24h forecast"),
            Entry(example: "ATIS KJFK",                                detail: "FAA D-ATIS where published"),
            Entry(example: "RWY EDDM",                                 detail: "All runways: length, surface, headings"),
            Entry(example: "sun EDDM",                                 detail: "Sunrise, sunset, civil twilight"),
            Entry(example: "altitude EDDM",                            detail: "Field / pressure / density altitude"),
            Entry(example: "briefing EDMA",                            detail: "METAR + TAF + ATIS + RWY + sun + altitude"),
            Entry(example: "wind 26 EDDM",                             detail: "Headwind / crosswind / tailwind from live METAR"),
            Entry(example: "distance EDDM to KSFO",                    detail: "Great-circle distance + true bearing"),
            Entry(example: "distance 48.35,11.78 to 37.62,-122.37",    detail: "Same, between raw lat/lon pairs"),
            Entry(example: "TOD FL350 to FL080 at -1500 fpm GS 450",   detail: "Top-of-descent distance"),
            Entry(example: "1500 fpm * 5 min in ft",                   detail: "Descent over time"),
        ]),
        Section(title: "Numbers & colour", entries: [
            Entry(example: "0xFF in dec",                              detail: "Hex → decimal"),
            Entry(example: "255 in hex",                               detail: "Decimal → hex"),
            Entry(example: "0b1011 in dec",                            detail: "Binary → decimal"),
            Entry(example: "255 in bin",                               detail: "Decimal → binary"),
            Entry(example: "0o17 in dec",                              detail: "Octal → decimal"),
            Entry(example: "MCMXC in dec",                             detail: "Roman → decimal (1..3999)"),
            Entry(example: "1990 in roman",                            detail: "Decimal → Roman"),
            Entry(example: "#FF9F0F in rgb",                           detail: "Hex colour → rgb()"),
            Entry(example: "rgb(255, 159, 15) in hex",                 detail: "rgb() → hex"),
            Entry(example: "hsl(36, 100%, 53%) in hex",                detail: "hsl() → hex"),
        ]),
        Section(title: "Syntax", entries: [
            Entry(example: "# heading",                                detail: "Section header (accent colour)"),
            Entry(example: "// full comment",                          detail: "Muted note, no result"),
            Entry(example: "2 + 2 // result",                          detail: "Trailing comment — line still evaluates"),
            Entry(example: "@slug",                                    detail: "Jump link to another page; muted+dotted if no doc matches"),
            Entry(example: "prev",                                     detail: "Refers to the last evaluated result"),
        ]),
        Section(title: "Keyboard", entries: [
            Entry(example: "⌘N",                                       detail: "New calculation"),
            Entry(example: "⌘⇧1 / ⌘⇧2 / ⌘⇧3",                          detail: "Jump to first / second / third pinned sheet"),
            Entry(example: "⌘?",                                       detail: "This quick reference"),
            Entry(example: "⌘,",                                       detail: "Preferences"),
            Entry(example: "Tab",                                      detail: "Accept the ghost suggestion / try-this hint"),
            Entry(example: "Esc",                                      detail: "Dismiss the ghost suggestion"),
        ]),
    ]

    private var filteredSections: [Section] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return Self.sections }
        return Self.sections.compactMap { section in
            let matches = section.entries.filter {
                $0.example.lowercased().contains(q)
                    || $0.detail.lowercased().contains(q)
                    || section.title.lowercased().contains(q)
            }
            return matches.isEmpty ? nil : Section(title: section.title, entries: matches)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()
                .overlay(VektorTheme.divider)

            searchBar

            Divider()
                .overlay(VektorTheme.divider)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    let sections = filteredSections
                    if sections.isEmpty {
                        Text("No patterns match '\(search)'.")
                            .font(.callout)
                            .foregroundStyle(VektorTheme.muted)
                            .padding(.top, 40)
                            .frame(maxWidth: .infinity)
                    } else {
                        ForEach(sections) { section in
                            sectionBlock(section)
                        }
                    }
                }
                .padding(18)
            }
        }
        .frame(width: 580, height: 680)
        .themedSheet()
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("QUICK REFERENCE")
                .font(.system(size: 11, weight: .medium))
                .tracking(1.8)
                .foregroundStyle(VektorTheme.muted)
            Spacer(minLength: 0)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .imageScale(.small)
                    .foregroundStyle(VektorTheme.muted)
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close (Esc)")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(VektorTheme.muted)
            TextField("Search patterns", text: $search)
                .textFieldStyle(.plain)
                .foregroundStyle(VektorTheme.text)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private func sectionBlock(_ section: Section) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(section.title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(VektorTheme.accent)
                .padding(.bottom, 2)
            ForEach(section.entries) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(entry.example)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(VektorTheme.text)
                        .frame(width: 240, alignment: .leading)
                        .textSelection(.enabled)
                    Text(entry.detail)
                        .font(.system(.callout))
                        .foregroundStyle(VektorTheme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 2)
            }
        }
    }
}
