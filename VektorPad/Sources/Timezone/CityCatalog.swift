import Foundation

/// A pickable city in the "add city" search. Identified by its IANA
/// timezone id + name so duplicates (same zone, different city) stay
/// distinct in the list.
struct CatalogCity: Identifiable, Hashable {
    let name: String
    let country: String
    let timeZoneId: String
    var id: String { "\(timeZoneId)|\(name)" }
}

/// A curated world-cities catalog. Each entry carries an IANA timezone id
/// so the app resolves the current local time with `TimeZone` +
/// `DateFormatter` — no engine round-trip needed for the v1 pane.
enum CityCatalog {
    static let all: [CatalogCity] = [
        // Americas
        .init(name: "New York",      country: "United States", timeZoneId: "America/New_York"),
        .init(name: "Los Angeles",   country: "United States", timeZoneId: "America/Los_Angeles"),
        .init(name: "Chicago",       country: "United States", timeZoneId: "America/Chicago"),
        .init(name: "Denver",        country: "United States", timeZoneId: "America/Denver"),
        .init(name: "Toronto",       country: "Canada",        timeZoneId: "America/Toronto"),
        .init(name: "Mexico City",   country: "Mexico",        timeZoneId: "America/Mexico_City"),
        .init(name: "São Paulo",     country: "Brazil",        timeZoneId: "America/Sao_Paulo"),
        .init(name: "Buenos Aires",  country: "Argentina",     timeZoneId: "America/Argentina/Buenos_Aires"),
        // Europe
        .init(name: "London",        country: "United Kingdom", timeZoneId: "Europe/London"),
        .init(name: "Dublin",        country: "Ireland",        timeZoneId: "Europe/Dublin"),
        .init(name: "Lisbon",        country: "Portugal",       timeZoneId: "Europe/Lisbon"),
        .init(name: "Paris",         country: "France",         timeZoneId: "Europe/Paris"),
        .init(name: "Madrid",        country: "Spain",          timeZoneId: "Europe/Madrid"),
        .init(name: "Barcelona",     country: "Spain",          timeZoneId: "Europe/Madrid"),
        .init(name: "Berlin",        country: "Germany",        timeZoneId: "Europe/Berlin"),
        .init(name: "Munich",        country: "Germany",        timeZoneId: "Europe/Berlin"),
        .init(name: "Amsterdam",     country: "Netherlands",    timeZoneId: "Europe/Amsterdam"),
        .init(name: "Zurich",        country: "Switzerland",    timeZoneId: "Europe/Zurich"),
        .init(name: "Rome",          country: "Italy",          timeZoneId: "Europe/Rome"),
        .init(name: "Athens",        country: "Greece",         timeZoneId: "Europe/Athens"),
        .init(name: "Istanbul",      country: "Türkiye",        timeZoneId: "Europe/Istanbul"),
        .init(name: "Moscow",        country: "Russia",         timeZoneId: "Europe/Moscow"),
        // Africa / Middle East
        .init(name: "Lagos",         country: "Nigeria",        timeZoneId: "Africa/Lagos"),
        .init(name: "Cairo",         country: "Egypt",          timeZoneId: "Africa/Cairo"),
        .init(name: "Nairobi",       country: "Kenya",          timeZoneId: "Africa/Nairobi"),
        .init(name: "Johannesburg",  country: "South Africa",   timeZoneId: "Africa/Johannesburg"),
        .init(name: "Dubai",         country: "UAE",            timeZoneId: "Asia/Dubai"),
        .init(name: "Tel Aviv",      country: "Israel",         timeZoneId: "Asia/Jerusalem"),
        // Asia
        .init(name: "Mumbai",        country: "India",          timeZoneId: "Asia/Kolkata"),
        .init(name: "Bangkok",       country: "Thailand",       timeZoneId: "Asia/Bangkok"),
        .init(name: "Jakarta",       country: "Indonesia",      timeZoneId: "Asia/Jakarta"),
        .init(name: "Bali",          country: "Indonesia",      timeZoneId: "Asia/Makassar"),
        .init(name: "Singapore",     country: "Singapore",      timeZoneId: "Asia/Singapore"),
        .init(name: "Hong Kong",     country: "Hong Kong",      timeZoneId: "Asia/Hong_Kong"),
        .init(name: "Shanghai",      country: "China",          timeZoneId: "Asia/Shanghai"),
        .init(name: "Seoul",         country: "South Korea",    timeZoneId: "Asia/Seoul"),
        .init(name: "Tokyo",         country: "Japan",          timeZoneId: "Asia/Tokyo"),
        // Oceania
        .init(name: "Perth",         country: "Australia",      timeZoneId: "Australia/Perth"),
        .init(name: "Sydney",        country: "Australia",      timeZoneId: "Australia/Sydney"),
        .init(name: "Auckland",      country: "New Zealand",    timeZoneId: "Pacific/Auckland"),
        .init(name: "Honolulu",      country: "United States",  timeZoneId: "Pacific/Honolulu"),
    ]

    static func search(_ query: String) -> [CatalogCity] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        return all.filter {
            $0.name.localizedCaseInsensitiveContains(q) ||
            $0.country.localizedCaseInsensitiveContains(q)
        }
    }
}
