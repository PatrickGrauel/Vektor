import Foundation
import SwiftUI

/// A single Vektor document — multi-line text whose first non-empty line acts
/// as the title. Persisted as a list in UserDefaults.
struct TallyDocument: Identifiable, Codable, Equatable {
    var id: UUID
    var content: String
    var updatedAt: Date
    /// User-pinned to the top of the documents list. Pins survive
    /// across sessions via the same UserDefaults blob. Optional in
    /// the encoded form so notes saved before this field existed
    /// still decode cleanly.
    var isPinned: Bool

    init(id: UUID = UUID(),
         content: String = "",
         updatedAt: Date = .now,
         isPinned: Bool = false) {
        self.id = id
        self.content = content
        self.updatedAt = updatedAt
        self.isPinned = isPinned
    }

    enum CodingKeys: String, CodingKey {
        case id, content, updatedAt, isPinned
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id        = try c.decode(UUID.self,   forKey: .id)
        self.content   = try c.decode(String.self, forKey: .content)
        self.updatedAt = try c.decode(Date.self,   forKey: .updatedAt)
        self.isPinned  = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    }

    /// First non-empty / non-comment line, trimmed and truncated.
    var title: String {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            // Strip header / comment markers so titles read naturally.
            let stripped = trimmed
                .replacingOccurrences(of: "^#+\\s*", with: "", options: .regularExpression)
                .replacingOccurrences(of: "^//\\s*", with: "", options: .regularExpression)
            if stripped.isEmpty { continue }
            return String(stripped.prefix(60))
        }
        return "Scratch something"
    }

    /// First-word slug used as the target of `@reference` jumps from
    /// other documents. Lowercased, alphanumeric + `-` + `_` only.
    /// Two documents that produce the same slug both work as targets
    /// (most-recently-modified wins).
    var slug: String {
        let raw = title
        let firstWord = raw.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "_" })
            .first ?? Substring("")
        return firstWord.lowercased()
    }
}

@MainActor
final class DocumentStore: ObservableObject {
    @Published var documents: [TallyDocument]
    @Published var selectedID: UUID

    private static let storageKey = "tally.documents.v1"
    private static let lastSelectedKey = "tally.documents.lastSelected"

    init() {
        let loaded = Self.load()
        var initial: [TallyDocument]
        if loaded.isEmpty {
            // Seed first launch with a welcoming hub doc + eight
            // topic-focused docs it links to via `@references`. The
            // welcome doc is intentionally short — it's an index, not
            // a tutorial. Each topic page is short, copy-pasteable,
            // and runs in real time so the user sees something
            // useful within seconds of clicking through.
            initial = Self.welcomePackage()
        } else {
            initial = loaded
        }
        // Defensive: if `loaded` somehow returned an empty array (corrupt
        // file, future migration that allows zero docs), seed a fresh one
        // so the rest of the store can rely on at least one document.
        if initial.isEmpty {
            initial = [TallyDocument(content: "")]
        }
        self.documents = initial

        let storedID = UserDefaults.standard.string(forKey: Self.lastSelectedKey)
            .flatMap(UUID.init(uuidString:))
        if let storedID, initial.contains(where: { $0.id == storedID }) {
            self.selectedID = storedID
        } else if let first = initial.first {
            self.selectedID = first.id
        } else {
            // Unreachable due to the seeding above, but the type system
            // still demands a non-optional UUID here.
            self.selectedID = UUID()
        }

        if loaded.isEmpty { persist() }
    }

    // MARK: - Selection

    var selected: TallyDocument {
        get { documents.first(where: { $0.id == selectedID }) ?? documents[0] }
        set {
            guard let idx = documents.firstIndex(where: { $0.id == newValue.id }) else { return }
            documents[idx] = newValue
            persist()
        }
    }

    func select(_ id: UUID) {
        guard documents.contains(where: { $0.id == id }) else { return }
        selectedID = id
        UserDefaults.standard.set(id.uuidString, forKey: Self.lastSelectedKey)
    }

    // MARK: - Mutations

    func updateSelectedContent(_ content: String) {
        guard let idx = documents.firstIndex(where: { $0.id == selectedID }) else { return }
        documents[idx].content = content
        documents[idx].updatedAt = .now
        persist()
    }

    @discardableResult
    func newDocument() -> TallyDocument {
        let doc = TallyDocument(content: "")
        documents.insert(doc, at: 0)
        selectedID = doc.id
        UserDefaults.standard.set(doc.id.uuidString, forKey: Self.lastSelectedKey)
        persist()
        return doc
    }

    func delete(_ id: UUID) {
        guard documents.count > 1 else { return }   // never let users go to zero docs
        documents.removeAll { $0.id == id }
        if selectedID == id, let first = documents.first {
            selectedID = first.id
            UserDefaults.standard.set(selectedID.uuidString, forKey: Self.lastSelectedKey)
        }
        persist()
    }

    func filtered(searching query: String) -> [TallyDocument] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let base = sortedForListing(documents)
        guard !q.isEmpty else { return base }
        return base.filter { $0.content.localizedCaseInsensitiveContains(q) }
    }

    /// Pins-first sort. Inside each group the most-recently-updated
    /// document floats to the top — matches Numi's "what did I
    /// touch last?" mental model.
    private func sortedForListing(_ list: [TallyDocument]) -> [TallyDocument] {
        list.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned && !b.isPinned }
            return a.updatedAt > b.updatedAt
        }
    }

    // MARK: - Pinning

    func togglePinned(_ id: UUID) {
        guard let idx = documents.firstIndex(where: { $0.id == id }) else { return }
        documents[idx].isPinned.toggle()
        documents[idx].updatedAt = .now
        persist()
    }

    // MARK: - @ slug navigation

    /// Resolve a slug to a document. Used by `@reference` clicks in
    /// the calculator editor. Most-recently-modified wins when more
    /// than one document shares the same slug.
    func findBySlug(_ slug: String) -> TallyDocument? {
        let q = slug.lowercased()
        return documents
            .filter { $0.slug == q }
            .sorted { $0.updatedAt > $1.updatedAt }
            .first
    }

    /// Navigate to the document matching `slug`, no-op if no match.
    /// Returns true if navigation happened (useful for the click
    /// handler — it falls through to default caret placement when
    /// no jump occurred).
    @discardableResult
    func selectBySlug(_ slug: String) -> Bool {
        guard let doc = findBySlug(slug) else { return false }
        select(doc.id)
        return true
    }

    /// All current slug → title pairs. Used by the (planned) `@`
    /// autocomplete popover.
    func allSlugs() -> [(slug: String, title: String, id: UUID)] {
        documents
            .filter { !$0.slug.isEmpty }
            .map { ($0.slug, $0.title, $0.id) }
    }

    // MARK: - Persistence

    private func persist() {
        if let data = try? JSONEncoder().encode(documents) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    private static func load() -> [TallyDocument] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([TallyDocument].self, from: data)
        else { return [] }
        return decoded
    }

    // MARK: - First-launch seed

    /// Nine docs the new user lands with:
    ///   • Welcome to Vektor   — short hub, links to the others via @refs
    ///   • Math                — arithmetic + variables + prev
    ///   • Units               — kt → km/h, °F → °C, the bread and butter
    ///   • Money               — FX, crypto, live stock quotes
    ///   • Time                — time-zone math + Zulu / local conversions
    ///   • Dates               — days between, age, weekday-of-date
    ///   • Aviation            — METAR / TAF / RWY / sun / altitude
    ///   • Stocks              — DCA scoring + FMP setup pointer
    ///   • Tips                — keyboard shortcuts and pane tour
    ///
    /// Welcome is pinned so it stays at the top of the list. The
    /// linked docs aren't pinned — once the user has explored, they
    /// fall to where their `updatedAt` puts them.
    private static func welcomePackage() -> [TallyDocument] {
        // Insert order matters for the sidebar list — newest first
        // is the default sort, so build in reverse-chronological
        // order with the welcome doc *last* (most recent → top).
        let now = Date()
        func at(_ offsetSeconds: TimeInterval) -> Date {
            now.addingTimeInterval(offsetSeconds)
        }

        let math = TallyDocument(content: """
        # Math
        // Arithmetic, variables, and the "prev" trick.

        # The classics
        2 + 2
        8 * (3.5 + 1)
        sqrt(2)
        sin(45°) ^ 2 + cos(45°) ^ 2     // hello there, Pythagoras

        # prev = the last result
        // Saves you copy-paste hell on multi-step calculations.
        100 / 7
        prev * 12                        // builds on the line above
        prev + 1                         // and the line above that

        # Variables — name a number, reuse it forever
        rent = 1450 EUR
        rent * 12                        // a year of rent
        rent * 12 * 30 / 1000            // a career of rent, in thousands

        // Variable names are case-insensitive. Rent and RENT are the same var.

        # Where to next?
        // Try @units, or jump back to @welcome.
        """, updatedAt: at(-80))

        let units = TallyDocument(content: """
        # Units
        // Type a number + a unit, then "to" or "in" + the target unit.
        // Vektor handles everything from kitchens to cockpits.

        # Speed and length
        120 kt in km/h                   // pilot speeds
        60000 ft in m                    // pilot altitudes
        100 km/h in mph                  // road speeds

        # Pressure, weight, temperature
        29.92 inHg in hPa                // standard pressure
        180 lbs in kg
        100°F in °C
        -40°C in °F                      // the temperature where the scales meet

        # Time and energy
        2 hours in seconds
        5400 W * 3 hours in kWh          // how much that EV charge actually used

        # Mixed-unit math just works
        (5 km + 800 m) in miles
        1 light year in km               // for perspective

        # Next stop
        // Try @money for currencies, @time for time zones,
        // or @aviation if knots and inHg are your daily bread.
        """, updatedAt: at(-70))

        let money = TallyDocument(content: """
        # Money
        // Live rates fetched quietly in the background. No clicks,
        // no refresh buttons. FX from the ECB, crypto from public
        // exchanges, single stocks from FMP (your key in Settings).

        # Plain FX
        100 EUR in USD
        2500 USD in JPY
        50 GBP in CHF

        # Mix currencies and math
        rent = 1450 EUR
        rent * 12 in USD                 // your annual rent, in dollars

        # Crypto, same syntax
        1 BTC in USD
        0.5 ETH in EUR

        # Live single-stock price
        stock AAPL                       // needs your FMP key — Settings → Stocks
        stock MSFT
        stock KO

        # The deep dive lives elsewhere
        // The full Buffett scorecard + sector P/E + radar chart
        // for any covered ticker lives in @stocks (the dedicated pane).

        // Back to @welcome.
        """, updatedAt: at(-60))

        let time = TallyDocument(content: """
        # Time
        // For people in the wrong hemispheres, on the wrong calendars,
        // or both.

        # Current time anywhere
        Berlin time
        Tokyo time
        SFO time                         // IATA airport codes work too
        EDDM time                        // ICAO codes work too

        # Zulu and conversions
        1430 Zulu in HKT                 // briefing time → Hong Kong
        now in Tokyo + 2h                // what time will it be there in 2h?

        # Going the other way
        9am tomorrow Berlin in PT        // when is your 9am Berlin in Pacific?

        # See also
        // Date math: @dates. Pilot stuff: @aviation. Back to @welcome.
        """, updatedAt: at(-50))

        let dates = TallyDocument(content: """
        # Dates
        // For procrastinators, parents, and project managers.

        # The basics
        today
        days between today and 2026-12-25
        age 1990-03-15                   // your age right now, by year
        weekday 2026-07-04               // what day of the week is the 4th?

        # Mix with units
        days between today and 2026-12-25 in weeks
        days between today and 2026-12-25 in months

        # Combine with money
        deadline = 2026-12-31
        savings_target = 5000 EUR
        savings_target / (days between today and deadline)   // EUR per day to hit it

        # Next
        // Time-zone math: @time. Money: @money. Back: @welcome.
        """, updatedAt: at(-40))

        let aviation = TallyDocument(content: """
        # Aviation
        // ICAO and IATA codes both work. Multiple stations on one
        // line is supported: METAR EDDM EDMO LOWS.

        # Live weather
        METAR EDDM                       // Munich — also appends best runway by wind
        TAF KSFO                         // San Francisco 24h forecast
        ATIS KJFK                        // FAA D-ATIS where published

        # Runway, sun, altitude
        RWY EDDM                         // every runway: length, surface, heading
        sun EDDM                         // sunrise, sunset, civil twilight today
        altitude EDDM                    // field, pressure, and density altitude

        # The whole briefing in one line
        briefing EDMA                    // METAR + TAF + ATIS + RWY + sun + altitude

        # Pilot-specific math
        120 kt in km/h
        60000 ft in m
        29.92 inHg in hPa
        1500 fpm * 5 min in ft           // descent in 5 minutes at 1500 fpm

        # The richer aviation tools
        // Wind triangles, W&B, E6B all live in the Aviation pane.
        // Back to @welcome. Or see @stocks for the investing pane.
        """, updatedAt: at(-30))

        let stocks = TallyDocument(content: """
        # Stocks
        // Two flavours: a single price lookup right here in the
        // calculator, and a full Buffett-style scorecard in the
        // dedicated Stocks pane.

        # Right here — live single quotes
        stock AAPL                       // needs your FMP key (Settings → Stocks)
        stock MSFT
        stock KO

        # The deeper analysis
        // Switch to the Stocks pane (enable it in Manage Panes if
        // hidden). You get:
        //   • Six-axis radar chart of Buffett's DCA framework
        //   • Live current price + 1-month chart + fair-value chip
        //     (P/E vs sector average)
        //   • WKN + ISIN for the German-listed crowd
        //   • Fuzzy search — type "Tesla" if you don't know TSLA

        # FMP setup
        // Free key from financialmodelingprep.com. Free tier covers
        // ~50 analyses/day of major US-listed tickers. Paid plans
        // unlock international + history. Settings → Stocks.

        // Tips for everything else: @tips. Back to @welcome.
        """, updatedAt: at(-20))

        let tips = TallyDocument(content: """
        # Tips
        // The shortcuts and small touches that make Vektor pleasant.

        # Keyboard
        // ⌘N            — new calculation
        // ⌘L            — show all your calculations
        // ⌘1 / ⌘2 …     — switch pane (in order they appear in the menu)

        # In the documents list (⌘L)
        // Right-click any row → Pin to top, Delete
        // Search field filters by content (not just title)

        # Syntax cheat-sheet
        // #  at line start  →  section header (orange)
        // // at line start  →  full-line comment (muted, no result)
        // // after a value  →  trailing comment (line still evaluates)
        // @slug             →  jump link to another page

        # The "prev" trick
        // prev refers to the most recent result. Multi-step math
        // becomes readable:
        100                              // start with a price
        prev * 0.19                      // VAT
        prev + 100                       // total

        # Variables
        // Name a number once, reuse it. Case-insensitive.
        principal = 250000 EUR
        rate = 0.034
        years = 25
        principal * rate * years         // simple-interest cost

        # Where to next
        // Hub: @welcome. Or pick a topic: @math @units @money
        // @time @dates @aviation @stocks.
        """, updatedAt: at(-10))

        // Welcome lives last so it lands at the top of the list and
        // is also the first thing the user sees. Pinned so it stays
        // there until they explicitly unpin.
        let welcome = TallyDocument(content: """
        # Welcome to Vektor
        // A calculator that thinks too much. It does the boring
        // math. It also does units, currencies, time zones, dates,
        // METARs, runways, stock quotes — basically anything you'd
        // otherwise open four tabs for.

        # How this works
        // Every line below is its own live calculation. The answer
        // appears in the gutter on the right as you type. Comments
        // and headers don't try to calculate:
        //
        //   # heading        → orange, organises the doc
        //   // full comment  → muted side note, ignored
        //   2 + 2 // result  → line still evaluates; comment ignored
        //   @slug            → click to jump to that page

        # Try it now
        2 + 2
        120 kt in km/h                   // unit conversion in plain English
        100 EUR in USD                   // live FX rate
        Berlin time                      // current time anywhere

        # Topic pages — click any @link to jump
        // Start anywhere. Each page is short and runs in real time.
        //
        //   @math      — arithmetic, variables, the "prev" trick
        //   @units     — knots, hPa, kilowatts, the lot
        //   @money     — FX, crypto, live single stocks
        //   @time      — time-zone math
        //   @dates     — days-between, age, weekdays
        //
        // For specialists:
        //   @aviation  — METAR / TAF / RWY / sun / altitude
        //   @stocks    — Buffett scorecard + FMP setup
        //   @tips      — keyboard shortcuts + syntax cheat-sheet

        # Housekeeping
        // ⌘N for a new page · ⌘L to see all pages · right-click
        // any page → Pin to keep it on top. This Welcome doc is
        // pinned by default; right-click → Unpin if you'd rather it
        // wasn't.
        //
        // This page is yours. Edit it, gut it, delete it. Vektor
        // won't take it personally.
        """, updatedAt: at(0), isPinned: true)

        return [welcome, tips, stocks, aviation, dates, time, money, units, math]
    }
}
