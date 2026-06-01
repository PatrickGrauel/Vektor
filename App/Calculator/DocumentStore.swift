import Foundation
import SwiftUI

/// A single Vektor document — multi-line text whose first non-empty line acts
/// as the title. Persisted as a list in UserDefaults.
struct VektorDocument: Identifiable, Codable, Equatable {
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
    @Published var documents: [VektorDocument]
    @Published var selectedID: UUID

    private static let storageKey = "vektor.documents.v1"
    private static let lastSelectedKey = "vektor.documents.lastSelected"

    init() {
        let loaded = Self.load()
        var initial: [VektorDocument]
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
            initial = [VektorDocument(content: "")]
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

        // Flush any pending debounced save when the app is about to quit
        // so the typing window between the last keystroke and the
        // debounce expiry can't lose data.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.persistTask != nil else { return }
                self.persist()
            }
        }
    }

    // MARK: - Selection

    var selected: VektorDocument {
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
        schedulePersist()
    }

    @discardableResult
    func newDocument() -> VektorDocument {
        let doc = VektorDocument(content: "")
        documents.insert(doc, at: 0)
        selectedID = doc.id
        UserDefaults.standard.set(doc.id.uuidString, forKey: Self.lastSelectedKey)
        persist()
        return doc
    }

    /// Insert a topic example as a new document. Drives the "+ from
    /// example…" menu — lets users pull in a pre-built reference page
    /// (Math, Units, Money, Aviation…) on demand rather than getting
    /// all of them slammed on at first launch.
    @discardableResult
    func newDocument(fromExample example: ExampleTemplate) -> VektorDocument {
        let doc = VektorDocument(content: example.content)
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

    func filtered(searching query: String) -> [VektorDocument] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let base = sortedForListing(documents)
        guard !q.isEmpty else { return base }
        return base.filter { $0.content.localizedCaseInsensitiveContains(q) }
    }

    /// Pins-first sort. Inside each group the most-recently-updated
    /// document floats to the top — matches Numi's "what did I
    /// touch last?" mental model.
    private func sortedForListing(_ list: [VektorDocument]) -> [VektorDocument] {
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
    func findBySlug(_ slug: String) -> VektorDocument? {
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

    /// Debounced trailing-edge save. Per-keystroke writes used to land on
    /// the main thread synchronously — at ~9 KB per encode-and-write that
    /// added up. Coalescing into one save per typing burst removes that
    /// cost from the keystroke path without meaningfully widening the
    /// data-loss window.
    private var persistTask: Task<Void, Never>?
    private static let persistDebounce: Duration = .milliseconds(400)

    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: Self.persistDebounce)
            guard !Task.isCancelled, let self else { return }
            self.persist()
        }
    }

    private func persist() {
        // Any caller that wants an immediate save (newDocument, delete,
        // togglePinned, etc.) cancels the pending debounce here so we
        // can't accidentally clobber the just-saved state with an
        // older snapshot a moment later.
        persistTask?.cancel()
        persistTask = nil
        if let data = try? JSONEncoder().encode(documents) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    private static func load() -> [VektorDocument] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([VektorDocument].self, from: data)
        else { return [] }
        return decoded
    }

    // MARK: - First-launch seed
    //
    // New users land on ONE curated welcome doc — a live, editable
    // playground with sections per feature area. Each section has
    // 2–3 working demos the user can tweak; the gutter updates as
    // they type. This replaces an older 9-doc package that read more
    // like a wiki than a calculator and overwhelmed first-launch.
    //
    // The 8 original topic docs are preserved as `exampleTemplates`,
    // accessible via the "+ from example…" menu — users pull them in
    // on demand when they want a topic-focused reference page.

    /// One self-contained welcome doc the user can edit, gut, or
    /// delete. Pinned so it stays at the top until they explicitly
    /// unpin. Cross-references `@math`, `@units` etc. all render as
    /// "muted + dotted" until the user inserts those templates —
    /// which is itself a discovery hint pointing at the menu.
    private static func welcomePackage() -> [VektorDocument] {
        let welcome = VektorDocument(content: """
        # Welcome to Vektor
        // A calculator that thinks too much. Type any line — the
        // answer appears in the gutter on the right as you type.
        // Edit any line below; the result updates live.

        # Math
        2 + 2
        sqrt(2)
        sin(45°) ^ 2 + cos(45°) ^ 2     // hello there, Pythagoras

        # Units (use `in` or `to`)
        10 mi in km
        180 lbs in kg
        100°F in °C

        # Money (live FX, no key needed)
        100 EUR in USD
        1 BTC in USD

        # Time
        Berlin time
        1430 Zulu in HKT
        77/55 in hours                   // duration from a quotient

        # Dates
        today
        days between today and 2026-12-25
        age 1990-03-15

        # Aviation
        METAR EDDM
        TAF KSFO
        RWY EDDM

        # Variables and `prev`
        rent = 1450 EUR
        rent * 12                        // a year of rent
        100 / 7
        prev * 12                        // builds on the line above

        # Syntax
        // #  heading       → orange section header
        // // comment       → muted line, no result
        // @slug            → jump link; muted+dotted means "no doc yet"
        //
        // Press ⌘? any time for the full quick reference. Or hit Tab
        // on any blank line to drop in a sample expression.

        # Now make it yours
        // Delete every line above — Vektor won't take it personally.
        // ⌘N for a fresh page. The + button → "From example…" drops
        // in a topic page (@math, @units, @aviation…) if you want a
        // dedicated reference around.
        """, isPinned: true)

        return [welcome]
    }

    /// A topic example the user can pull in as a new document via the
    /// "+ from example…" menu. Title is human-readable; content is
    /// dropped into the doc verbatim.
    struct ExampleTemplate: Identifiable {
        let title: String
        let content: String
        var id: String { title }
    }

    /// The eight topic pages that used to be force-fed on first launch.
    /// Now optional: users pull in any of them via the "+" menu when
    /// they want a dedicated reference. Order matches conceptual
    /// progression (basics → specialist).
    static let exampleTemplates: [ExampleTemplate] = {
        let math = ExampleTemplate(title: "Math", content: """
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
        """)

        let units = ExampleTemplate(title: "Units", content: """
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
        """)

        let money = ExampleTemplate(title: "Money", content: """
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
        """)

        let time = ExampleTemplate(title: "Time", content: """
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
        16:30 Bali time in Munich        // 24-hour
        4.30pm Uluwatu time in Barcelona // European dot + glued pm
        now in Tokyo + 2h                // what time will it be there in 2h?

        # Going the other way
        9am tomorrow Berlin in Los Angeles   // when is your 9am Berlin in LA tomorrow?

        # Duration from a calculation
        77/55 in hours                   // fuel ÷ burn → 1h 24min endurance
        20/60 in hours                   // 20min
        2.5 in hours                     // 2h 30min
        816 in minutes                   // 13h 36min 00sec
        3725 in seconds                  // 1h 02min 05sec

        # See also
        // Date math: @dates. Pilot stuff: @aviation. Back to @welcome.
        """)

        let dates = ExampleTemplate(title: "Dates", content: """
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
        """)

        let aviation = ExampleTemplate(title: "Aviation", content: """
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
        """)

        let stocks = ExampleTemplate(title: "Stocks", content: """
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
        """)

        let tips = ExampleTemplate(title: "Tips", content: """
        # Tips
        // The shortcuts and small touches that make Vektor pleasant.

        # Keyboard
        // ⌘N            — new calculation
        // ⌘?            — open the quick reference
        // ⌘⇧1 / ⌘⇧2 …  — jump to first / second pinned sheet
        // ⌘1 / ⌘2 …     — switch pane (in order they appear in the menu)

        # Sheet switcher (click the SHEET title at the top)
        // Pinned sheets at the top, everything else below the divider.
        // Click the pin icon on any row to pin/unpin; trash to delete.

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
        """)

        return [math, units, money, time, dates, aviation, stocks, tips]
    }()
}
