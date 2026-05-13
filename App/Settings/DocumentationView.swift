import SwiftUI

/// Human-written manual for Tally. Opened from Preferences via a "Documentation"
/// button. Single scrollable view with a sidebar for jumping between sections.
/// The tone is conversational and concrete: examples first, prose second.
struct DocumentationView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Section = .basics

    enum Section: String, CaseIterable, Identifiable {
        case basics    = "The basics"
        case operators = "Operators"
        case percent   = "Percentages"
        case variables = "Variables & headers"
        case units     = "Units"
        case money     = "Currency"
        case time      = "Time & timezones"
        case functions = "Functions"
        case aviation  = "Aviation"
        case weather   = "METAR / TAF / ATIS"
        case docs      = "Documents"
        case menubar   = "Menu bar"
        case missing   = "What's missing"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $selected) { s in
                Text(s.rawValue).tag(s)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .listStyle(.sidebar)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    content
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                // Constrain paragraph width so prose stays readable on a
                // wide-resized window. ~720pt gives roughly 70–80 chars
                // per line at the body size we use.
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(TallyTheme.background)
        }
        .frame(minWidth: 760, minHeight: 520)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .navigationTitle("Tally documentation")
        .themedSheet()
    }

    @ViewBuilder
    private var content: some View {
        switch selected {
        case .basics:    basicsSection
        case .operators: operatorsSection
        case .percent:   percentSection
        case .variables: variablesSection
        case .units:     unitsSection
        case .money:     moneySection
        case .time:      timeSection
        case .functions: functionsSection
        case .aviation:  aviationSection
        case .weather:   weatherSection
        case .docs:      docsSection
        case .menubar:   menubarSection
        case .missing:   missingSection
        }
    }

    // MARK: - Sections

    private var basicsSection: some View {
        Doc(title: "Type math, see the answer") {
            Doc_.paragraph("Tally is a calculator that works the way you'd write things on a napkin. There's no equals key — you just type and Tally computes as you go. The answer for each line appears on the right.")
            Doc_.code("""
            2 + 2
            8 times 9
            1 meter in cm
            20% of 50
            100 - 5%
            2:30 pm HKT in Berlin
            """)
            Doc_.paragraph("Blank lines are decorative. Lines starting with `#` are headers; lines starting with `//` are comments. Both are display-only.")
        }
    }

    private var operatorsSection: some View {
        Doc(title: "Operators") {
            Doc_.paragraph("Math operators work both as symbols and as words:")
            Doc_.table([
                ["Add", "`+`, `plus`, `and`, `with`"],
                ["Subtract", "`-`, `minus`, `subtract`, `without`"],
                ["Multiply", "`*`, `times`, `multiplied by`"],
                ["Divide", "`/`, `divide by`"],
                ["Power", "`^`"],
                ["Modulo", "`mod`"],
                ["Bitwise AND / OR / XOR", "`&`, `|`, `xor`"],
                ["Left / right shift", "`<<`, `>>`"]
            ])
            Doc_.code("""
            8 times 9         → 72
            120 mod 7         → 1
            0b1100 xor 0b1010 → 6
            """)
        }
    }

    private var percentSection: some View {
        Doc(title: "Percentages") {
            Doc_.paragraph("Tally knows the shapes percentages usually take in spoken math:")
            Doc_.code("""
            20% of 50          →  10
            100 - 5%           →  95
            5% on $30          →  $31.50      (add 5% to $30)
            6% off 40 EUR      →  37.60 EUR   (subtract 6%)
            $50 as a % of $100 →  50%
            """)
            Doc_.paragraph("`% of`, `% on`, `% off`, `% as a % of/on/off` — all do the obvious thing.")
        }
    }

    private var variablesSection: some View {
        Doc(title: "Variables & headers") {
            Doc_.paragraph("Assign with `=`. The name has to start with a letter and can't contain spaces or special characters. The variable lives for the rest of the document.")
            Doc_.code("""
            House    = 500_000 EUR
            Mortgage = House * 0.8
            Mortgage / 240 months
            """)
            Doc_.paragraph("Headers start with `#`. The space is optional — `#Trip to Bali` works the same as `# Trip to Bali`. The line is shown but not evaluated.")
            Doc_.code("""
            # Trip to Bali
            #Trip to Bali       (also a header)
            // a comment         (also ignored)
            """)
            Doc_.paragraph("Three special tokens reference earlier lines:")
            Doc_.table([
                ["`prev`",   "Result of the previous line"],
                ["`sum`",    "Sum of all lines since the last blank line"],
                ["`average`","Average of those lines (`avg` is an alias)"]
            ])
        }
    }

    private var unitsSection: some View {
        Doc(title: "Units") {
            Doc_.paragraph("Tally understands physical units and mixes them freely. Conversion uses `in` or `to` — both mean the same thing.")
            Doc_.code("""
            1 m + 50 cm           →  1.5 m
            3 ft 6 in in cm       →  106.68 cm
            65 kg in lb           →  143.30 lb
            100 km/h in mph       →  62.14 mph
            500 hPa in inHg       →  14.77 inHg
            FL250 in ft           →  25 000 ft
            """)
            Doc_.paragraph("The categories Tally knows about:")
            Doc_.table([
                ["Length",      "m, km, cm, mm, μm, nm, in, ft, yd, mi, NM (nautical mile), parsec, ly, AU, fathom, furlong"],
                ["Mass",        "g, kg, mg, oz, lb, ton, stone, carat (ct)"],
                ["Volume",      "L, mL, dL, gallon, igallon (imperial), pint, ipint, quart, cup, tbsp, tsp"],
                ["Time",        "s, min, h, day, week, month, year"],
                ["Temperature", "K, degC (°C), degF (°F)"],
                ["Pressure",    "Pa, kPa, hPa, mbar, bar, atm, psi, inHg, mmHg, torr"],
                ["Speed",       "m/s, km/h (kmh, kph), mph, kt (kts, kn)"],
                ["Force",       "N, dyne, lbf, kp (kilopond), kgf"],
                ["Energy",      "J, kJ, MJ, BTU, Wh, kWh, MWh, GWh, cal (gram cal), Cal (kcal)"],
                ["Power",       "W, kW, MW, hp, ps (metric hp)"],
                ["Frequency",   "Hz, kHz, MHz, GHz, rpm"],
                ["Data",        "bit (b), byte (B), KB, MB, GB, KiB, MiB, GiB, kbps, Mbps, Gbps"],
                ["Angle",       "rad, deg, °, grad, arcsec, arcmin"]
            ])
            Doc_.paragraph("Missing something you use? File it as feedback — adding a unit is usually a one-line change.")
        }
    }

    private var moneySection: some View {
        Doc(title: "Currency") {
            Doc_.paragraph("Type an ISO 4217 code (`USD`, `EUR`, `GBP`, `JPY`, `BTC`…) or a common spelling (`dollar`, `euro`, `pound`, `yen`, `bitcoin`). Case doesn't matter — `100 eur in usd` works the same as `100 EUR in USD`.")
            Doc_.code("""
            100 EUR in USD
            $500 + 200 GBP in EUR
            1 BTC in USD
            """)
            Doc_.paragraph("Live rates come from OpenExchangeRates. Paste a free API key into Preferences → Foreign exchange and Tally refreshes hourly. Without a key, currency arithmetic still works — assignments stick, math composes — but conversion ratios default to 1:1 until rates load.")
        }
    }

    private var timeSection: some View {
        Doc(title: "Time and timezones") {
            Doc_.paragraph("Times in different timezones, converted however you ask:")
            Doc_.code("""
            Berlin time                  →  current local time in Berlin
            Time in Singapore            →  same
            2:30 pm HKT in Berlin        →  08:30 GMT+2
            14:30 Berlin in Canggu       →  20:30 GMT+8
            1430 Zulu + 2                →  16:30 GMT   (military time + offset)
            now + 52 min                 →  current local time + 52 min
            now + 2h + 52min             →  chained offsets are fine
            12 min + 15 min              →  27 minutes
            """)
            Doc_.paragraph("You can name any IATA / ICAO airport code, any major city, common abbreviations (Z, Zulu, UTC, GMT, EST, PST, CET, JST, HKT, AEST, WITA…), and anything else Apple's geocoder recognizes. Unknown names resolve asynchronously the first time and cache for next time.")
        }
    }

    private var functionsSection: some View {
        Doc(title: "Functions") {
            Doc_.paragraph("Trigonometric functions default to radians. Use `°` or `deg` for degrees.")
            Doc_.table([
                ["`sqrt(x)`",       "Square root"],
                ["`cbrt(x)`",       "Cube root"],
                ["`nthRoot(x, n)`", "n-th root (math.js spelling)"],
                ["`abs(x)`",        "Absolute value"],
                ["`ln(x)`",         "Natural log"],
                ["`log(x)`",        "Base-10 log"],
                ["`log(x, n)`",     "Base-n log"],
                ["`x!`",            "Factorial (write `5!`)"],
                ["`round(x)`",      "Nearest integer"],
                ["`ceil(x)`",       "Round up"],
                ["`floor(x)`",      "Round down"],
                ["`sin / cos / tan`", "Trig (`sin(45°)`)"],
                ["`asin / acos / atan`", "Inverse trig"],
                ["`sinh / cosh / tanh`", "Hyperbolic"],
                ["`min(...) / max(...)`", "Smallest / largest"],
                ["`mean(...) / median(...)`", "Aggregates"]
            ])
            Doc_.code("""
            sqrt(16)        →  4
            log(1000)       →  3
            log(8, 2)       →  3
            5!              →  120
            sin(45°)        →  0.707...
            """)
        }
    }

    private var aviationSection: some View {
        Doc(title: "Aviation") {
            Doc_.paragraph("A few calculations show up enough in flight planning that they have dedicated functions:")
            Doc_.code("""
            density_altitude(8000, 25, 29.92)   // PA ft, OAT °C, altimeter inHg
            pressure_altitude(5000, 29.42)
            isa_temp(10000)                      // ISA temp at altitude
            ground_speed(360, 100, 280, 20)      // course, TAS, wind from, wind kt
            heading(360, 100, 280, 20)           // TH for given course + wind
            crosswind(270, 300, 15)              // runway hdg, wind from, wind kt
            headwind(270, 300, 15)
            ete(180, 120)                        // distance, GS  →  hours
            tod(10000, 500, 120)                 // alt to lose, rate fpm, GS
            endurance(50, 10)                    // fuel, burn  →  hours
            """)
            Doc_.paragraph("Type `METAR EDDM` or `TAF KSFO` on a calculator line and the raw report appears in the gutter. The dedicated METAR / TAF tab gives you the decoded version with danger-flagged fields (TS, gusts ≥ 20 kt, vis < 3 SM, ceiling < 1000 ft) and a runway crosswind computer.")
            Doc_.paragraph("The E6B tab has the wind-triangle math, density altitude, runway components, and top-of-descent on separate sub-tabs with live diagrams.")
        }
    }

    private var weatherSection: some View {
        Doc(title: "METAR / TAF / ATIS") {
            Doc_.paragraph("Type a weather query as a calculator line — the raw report appears in the right gutter the moment it loads. The dedicated **METAR / TAF** pane gives you a decoded view with danger-flagged fields and a runway crosswind computer.")
            Doc_.code("""
            METAR EDDM        →  raw METAR for Munich
            TAF KSFO          →  TAF (forecast) for San Francisco
            ATIS KJFK         →  ATIS (FAA airports only)
            """)
            Doc_.paragraph("Each line shows **updated X min ago** in smaller text. If the report is more than an hour old, the suffix turns gold so you know to refresh.")
            Doc_.paragraph("Source: aviationweather.gov for METAR / TAF (free, no key). ATIS comes from datis.clowd.io — FAA airports only; non-US airports won't have ATIS available.")

            Doc_.paragraph("In the METAR / TAF pane, the decoded view paints values in colour when they're operationally relevant:")
            Doc_.table([
                ["**Wind**",       "Orange ≥ 20 kt gust · red ≥ 25 kt gust or ≥ 30 kt steady"],
                ["**Visibility**", "Orange < 3 SM · red < 1 SM"],
                ["**Ceiling**",    "Orange BKN/OVC < 1000 ft · red < 500 ft"],
                ["**Weather**",    "Orange for BR/HZ/SN · red for TS / FZRA / +RA / VA / DS"]
            ])

            Doc_.paragraph("Tally caches METARs and TAFs on disk. METARs older than 24 hours are pruned automatically. TAFs are kept only as long as they're still inside their validity period — once a forecast expires *and* it's older than 24 hours, it's removed.")
        }
    }

    private var docsSection: some View {
        Doc(title: "Documents") {
            Doc_.paragraph("Each tab in the documents popover (the `≡` button in the top-right) is a separate document. The first non-empty / non-comment line is its title. Add a new one with the `+` button, switch between them via the popover, delete with the trash icon that appears on hover.")
            Doc_.paragraph("Documents persist locally — they survive quits and reboots. No cloud sync yet.")
        }
    }

    private var menubarSection: some View {
        Doc(title: "Menu bar") {
            Doc_.paragraph("Tally puts a small equals-with-heading-bug glyph in the macOS menu bar.")
            Doc_.table([
                ["Left-click",  "Show or hide the window. The window follows you to the current Space."],
                ["Right-click", "Open / Preferences… / Menu Bar Only Mode / Quit."],
                ["Menu Bar Only Mode", "Hides the Dock icon. Tally becomes a menu-bar-only app — reopen via the icon."]
            ])
        }
    }

    private var missingSection: some View {
        Doc(title: "What's missing") {
            Doc_.paragraph("Honest list of things that aren't here yet:")
            Doc_.bullets([
                "Syntax highlighting in the editor.",
                "Synced scrolling between editor and result gutter.",
                "Global show/hide hotkey.",
                "iCloud sync of documents.",
                "Plugin / extension system.",
                "Drag-out export.",
                "Map-click-to-add for the Timezone tab."
            ])
            Doc_.paragraph("Send feedback from Preferences → Send feedback. Things with two or more requests jump the queue.")
        }
    }
}

// MARK: - Document UI primitives

private struct Doc<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(TallyTheme.text)
            content()
        }
    }
}

private extension Doc where Content == EmptyView {
    static func _noop() {}
}

// Helpers as top-level views (avoids the generic-inference issue when
// Doc<T>'s static methods can't pin Content from caller context).
private struct DocParagraph: View {
    let markdown: String
    var body: some View {
        Text(.init(markdown))
            .font(.system(size: 13.5))
            .foregroundStyle(TallyTheme.text)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct DocCode: View {
    let block: String
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(block)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(TallyTheme.text)
                .padding(12)
                .background(TallyTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

private struct DocTable: View {
    let rows: [[String]]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                HStack(alignment: .top, spacing: 16) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        Text(.init(cell))
                            .font(.system(size: 12.5))
                            .foregroundStyle(TallyTheme.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.vertical, 6)
                if idx < rows.count - 1 {
                    Divider().background(TallyTheme.muted.opacity(0.2))
                }
            }
        }
        .padding(12)
        .background(TallyTheme.surface.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct DocBullets: View {
    let items: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 8) {
                    Text("·").foregroundStyle(TallyTheme.muted)
                    Text(.init(item))
                        .font(.system(size: 13.5))
                        .foregroundStyle(TallyTheme.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// Static shorthand on a non-generic enum so call-sites don't need to spell
// out the generic parameter.
private enum Doc_ {
    static func paragraph(_ s: String) -> DocParagraph { DocParagraph(markdown: s) }
    static func code(_ s: String) -> DocCode { DocCode(block: s) }
    static func table(_ r: [[String]]) -> DocTable { DocTable(rows: r) }
    static func bullets(_ i: [String]) -> DocBullets { DocBullets(items: i) }
}
