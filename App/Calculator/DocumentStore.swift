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
        return "Untitled"
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
            let first = TallyDocument(content: """
            # Welcome to Tally
            // Type anywhere; results appear in the gutter on the right.

            # Arithmetic & natural language
            2 + 2
            8 times 9
            20% of 50
            100 - 5%

            # Units (all SI families work)
            1 meter in cm
            120 kt in km/h
            29.92 inHg in hPa

            # Currency (live rates load on launch — first time may show 1:1)
            100 eur in usd
            1 BTC in USD

            # Variables, prev, and aggregates
            rent = 1450 EUR
            rent * 12
            prev / 2
            sum

            # Date math
            days between 2024-01-15 and today
            age 1990-03-15
            days until 2026-12-25

            # Time formatting
            1,8 h in hh:mm:ss
            125 minutes in hh:mm

            # Timezones
            Berlin time
            2:30 pm HKT in Berlin
            1430 Zulu + 2

            # Finance one-liners
            loan 300k at 5.5% for 30 years
            compound 1000 at 7% for 10 years
            20% tip on 86.50 split 4

            # Lengths & dimensions
            12'6" + 8'3"
            4500 mm at 1:50
            concrete 6 m x 4 m x 0.15 m

            # Aviation
            density_altitude(8000, 25, 29.92)
            crosswind(270, 300, 15)
            METAR EDDM
            TAF KSFO
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
