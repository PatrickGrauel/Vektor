import Foundation
import SwiftUI

/// JSON-backed `UserDefaults` store for any `Codable & Identifiable` type.
///
/// Replaces the three near-identical concrete stores we used to have
/// (LoanStore, RealEstateStore, AircraftStore) with one shared shape:
/// `@Published saved`, `add(...)` with upsert, `remove(id:)`, plus the
/// load + persist on init / mutate.
///
/// The two store-level variations are passed at construction time:
///
/// - `matches` decides whether an incoming item replaces an existing
///   entry. Default: same `id`. Some stores (Loan, Real-Estate) dedupe
///   by `name` instead.
/// - `merge` decides what gets stored on replace. Default: the new
///   item wins. Stores that dedupe by name preserve the original id
///   here so future references stay stable.
@MainActor
final class PersistentStore<T: Codable & Identifiable>: ObservableObject where T.ID == UUID {
    @Published private(set) var saved: [T] = []

    private let storageKey: String
    private let matches: (T, T) -> Bool
    private let merge:   (T, T) -> T

    init(storageKey: String,
         matches: @escaping (T, T) -> Bool = { $0.id == $1.id },
         merge:   @escaping (T, T) -> T   = { _, new in new }) {
        self.storageKey = storageKey
        self.matches = matches
        self.merge = merge
        load()
    }

    func add(_ item: T) {
        if let idx = saved.firstIndex(where: { matches($0, item) }) {
            saved[idx] = merge(saved[idx], item)
        } else {
            saved.append(item)
        }
        persist()
    }

    func remove(_ id: UUID) {
        saved.removeAll { $0.id == id }
        persist()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([T].self, from: data)
        else { return }
        self.saved = decoded
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}

// MARK: - Concrete typealiases + factories
//
// Typealiases keep the old type names alive so `@EnvironmentObject` and
// the StateObject sites read naturally. Factories supply the per-store
// dedup strategy and persistence key.

typealias LoanStore       = PersistentStore<SavedLoan>
typealias RealEstateStore = PersistentStore<SavedRealEstateDeal>
typealias AircraftStore   = PersistentStore<SavedAircraft>

extension PersistentStore where T == SavedLoan {
    /// Loan scenarios dedupe by **name**: saving "Mortgage A" twice
    /// updates the existing entry in place and preserves its original
    /// UUID so anything that referenced that id stays valid.
    static func loans() -> LoanStore {
        LoanStore(
            storageKey: "tally.finance.loan.scenarios.v1",
            matches: { $0.name == $1.name },
            merge: { existing, new in
                var copy = new
                copy.id = existing.id
                return copy
            }
        )
    }
}

extension PersistentStore where T == SavedRealEstateDeal {
    /// Real-estate deals dedupe by **name** (same semantics as loans).
    static func deals() -> RealEstateStore {
        RealEstateStore(
            storageKey: "tally.finance.realestate.scenarios.v1",
            matches: { $0.name == $1.name },
            merge: { existing, new in
                var copy = new
                copy.id = existing.id
                return copy
            }
        )
    }
}

extension PersistentStore where T == SavedAircraft {
    /// Aircraft dedupe by **id**: the editor mutates a copy of the
    /// existing aircraft and saves it back under the same UUID.
    static func aircraft() -> AircraftStore {
        AircraftStore(storageKey: "tally.wb.savedAircraft")
    }
}
