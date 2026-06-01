import Foundation
import SwiftUI
import UIKit

/// A single Vektor document — multi-line text whose first non-empty line
/// acts as the title. Persisted as a list in UserDefaults. (Ported from the
/// macOS app; identical storage shape so a future iCloud sync can bridge
/// them.)
struct VektorDocument: Identifiable, Codable, Equatable {
    var id: UUID
    var content: String
    var updatedAt: Date
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

    enum CodingKeys: String, CodingKey { case id, content, updatedAt, isPinned }
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
            let stripped = trimmed
                .replacingOccurrences(of: "^#+\\s*", with: "", options: .regularExpression)
                .replacingOccurrences(of: "^//\\s*", with: "", options: .regularExpression)
            if stripped.isEmpty { continue }
            return String(stripped.prefix(60))
        }
        return "Scratch"
    }

    /// First-word slug used as the target of `@reference` jumps. Lowercased,
    /// alphanumeric + `-`/`_` only.
    var slug: String {
        let firstWord = title.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "_" }).first ?? Substring("")
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
        var initial = Self.load()
        if initial.isEmpty { initial = Self.welcomePackage() }
        if initial.isEmpty { initial = [VektorDocument(content: "")] }
        self.documents = initial

        let storedID = UserDefaults.standard.string(forKey: Self.lastSelectedKey)
            .flatMap(UUID.init(uuidString:))
        if let storedID, initial.contains(where: { $0.id == storedID }) {
            self.selectedID = storedID
        } else {
            self.selectedID = initial[0].id
        }

        if Self.load().isEmpty { persist() }

        // Flush any pending debounced save when the app heads to the
        // background (iOS rarely sends willTerminate — resignActive is the
        // reliable "we might get suspended" signal).
        NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
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
        documents.first(where: { $0.id == selectedID }) ?? documents[0]
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

    func delete(_ id: UUID) {
        guard documents.count > 1 else { return }   // never go to zero docs
        documents.removeAll { $0.id == id }
        if selectedID == id {
            selectedID = documents[0].id
            UserDefaults.standard.set(selectedID.uuidString, forKey: Self.lastSelectedKey)
        }
        persist()
    }

    func togglePinned(_ id: UUID) {
        guard let idx = documents.firstIndex(where: { $0.id == id }) else { return }
        documents[idx].isPinned.toggle()
        documents[idx].updatedAt = .now
        persist()
    }

    /// True when `slug` matches an existing document — drives `@ref` styling.
    func resolvesSlug(_ slug: String) -> Bool {
        let q = slug.lowercased()
        return documents.contains { $0.slug == q }
    }

    /// Pins-first, then most-recently-updated. Matches the macOS listing.
    var listed: [VektorDocument] {
        documents.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned && !b.isPinned }
            return a.updatedAt > b.updatedAt
        }
    }

    // MARK: - Persistence (debounced)

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

    private static func welcomePackage() -> [VektorDocument] {
        let welcome = VektorDocument(content: """
        # Welcome to Vektor
        // A calculator that thinks too much. Type any line — the
        // answer appears in the gutter on the right as you type.

        # Math
        2 + 2
        sqrt(2)
        sin(45°) ^ 2 + cos(45°) ^ 2

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
        77/55 in hours

        # Variables and `prev`
        rent = 1450 EUR
        rent * 12
        100 / 7
        prev * 12

        # Now make it yours
        // Delete every line above — Vektor won't take it personally.
        """, isPinned: true)
        return [welcome]
    }
}
