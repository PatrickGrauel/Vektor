import Foundation
import SwiftUI

/// A city the user has pinned to the Timezone pane. Persisted as a Codable
/// list in UserDefaults (same key family as the macOS app).
struct PinnedCity: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var country: String
    var timeZoneId: String

    init(id: UUID = UUID(), name: String, country: String, timeZoneId: String) {
        self.id = id
        self.name = name
        self.country = country
        self.timeZoneId = timeZoneId
    }

    init(_ city: CatalogCity) {
        self.init(name: city.name, country: city.country, timeZoneId: city.timeZoneId)
    }

    var timeZone: TimeZone { TimeZone(identifier: timeZoneId) ?? .current }
}

@MainActor
final class PinnedCityStore: ObservableObject {
    @Published var cities: [PinnedCity]

    private static let storageKey = "vektor.timezone.cities"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([PinnedCity].self, from: data),
           !decoded.isEmpty {
            cities = decoded
        } else {
            cities = Self.seed()
            persist()
        }
    }

    func add(_ city: CatalogCity) {
        // De-dupe on (zone + name) so the same city isn't pinned twice.
        guard !cities.contains(where: { $0.timeZoneId == city.timeZoneId && $0.name == city.name }) else { return }
        cities.append(PinnedCity(city))
        persist()
    }

    func remove(atOffsets offsets: IndexSet) {
        cities.remove(atOffsets: offsets)
        persist()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        cities.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(cities) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    /// Seed: the device's local zone plus a few hubs, so the pane is useful
    /// on first open.
    private static func seed() -> [PinnedCity] {
        var seed: [PinnedCity] = [
            PinnedCity(name: "Local", country: "This device", timeZoneId: TimeZone.current.identifier),
        ]
        let hubs = ["America/New_York", "Europe/London", "Asia/Tokyo"]
        for id in hubs {
            if let c = CityCatalog.all.first(where: { $0.timeZoneId == id }) {
                seed.append(PinnedCity(c))
            }
        }
        return seed
    }
}
