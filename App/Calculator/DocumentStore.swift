import Foundation
import SwiftUI

/// A single Tally document — multi-line text whose first non-empty line acts
/// as the title. Persisted as a list in UserDefaults.
struct TallyDocument: Identifiable, Codable, Equatable {
    var id: UUID
    var content: String
    var updatedAt: Date

    init(id: UUID = UUID(), content: String = "", updatedAt: Date = .now) {
        self.id = id
        self.content = content
        self.updatedAt = updatedAt
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
            // Seed the first launch with a welcome doc that doubles as a
            // hands-on tour. Light humor on the section breaks so it
            // reads less like documentation and more like a friendly nudge.
            // After first launch the user owns it — edit, delete, rename.
            let first = TallyDocument(content: """
            # Welcome to Tally
            // Each line is its own calculation. The answer pops up on the right.
            // Click anywhere to start typing — or scroll through these first.

            # The classics
            2 + 2
            8 * (3.5 + 1)
            prev / 2          // "prev" = the last result. Saves chaining math.

            # Units — Tally's bread and butter
            120 kt in km/h
            60000 ft in km
            29.92 inHg in hPa
            2 hours in seconds

            # Money (live rates, refreshed in the background)
            100 EUR in USD
            1 BTC in USD
            // Yes, even when BTC does the thing it does.

            # Time zones — for calling people in inconvenient hemispheres
            Berlin time
            1430 Zulu in HKT
            now in Tokyo + 2h

            # Dates — for procrastinators and birthdays alike
            days between today and 2026-12-25
            age 1990-03-15

            # Variables — name a number once, reuse it forever
            a = 100
            b = 2 * a
            c = a + b
            // Names are case-insensitive. Total_price and total_price are the same var.
            // Yes, this is the algebra they made you do in school.
            // Turns out it was for something.

            # Now the practical version — for when you really want to know
            # what something costs you:
            rent = 1450 EUR
            rent * 12
            // Spoiler: a lot.

            # Aviation — for the pilots in the room
            METAR EDDM         // Munich, live — auto-appends best runway by wind
            TAF KSFO           // San Francisco's forecast
            ATIS KJFK          // FAA D-ATIS where published
            RWY EDDM           // every runway with length, surface, heading
            sun EDDM           // sunrise, sunset, civil twilight for today
            altitude EDDM      // field elevation · pressure alt · density alt
            briefing EDMA      // …or all of the above for one airport, stacked
            // Type any ICAO code. Multiple at once works too: METAR EDDM EDMO.

            // ⌘N for a new scratchpad. ⌘L to see all of them.
            // This doc is yours — edit it, delete it, ignore it. We won't mind.
            """)
            initial = [first]
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
        guard !q.isEmpty else { return documents }
        return documents.filter { $0.content.localizedCaseInsensitiveContains(q) }
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
}
