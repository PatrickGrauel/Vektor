import Foundation

/// One airport in the OurAirports dataset (large/medium/small only — we
/// strip heliports, seaplane bases, balloonports, and closed entries at
/// build time before bundling). Sourced from `airports.csv`.
public struct AirportInfo: Sendable, Equatable {
    public enum Tier: String, Sendable, CaseIterable {
        case large, medium, small
    }

    public let ident: String         // 4-letter ICAO (or local code if no ICAO)
    public let tier: Tier
    public let name: String
    public let latitude: Double
    public let longitude: Double
    public let iata: String?         // 3-letter IATA, empty in CSV → nil here
    public let municipality: String?
    public let isoCountry: String?   // ISO-3166 alpha-2
}

/// Process-wide airport directory. Lazy-loaded on first query, parses
/// the bundled `airports.csv` (~48 000 airports worldwide), and builds
/// a 5°×5° grid index for O(1)-ish viewport queries.
///
/// Same provenance + refresh story as `RunwayDatabase`: 28-day
/// OurAirports snapshot at build time, no runtime fetch.
public final class AirportDatabase: @unchecked Sendable {

    public static let shared = AirportDatabase()

    /// Side of one grid cell, in degrees. 5° is the sweet spot: roughly
    /// 550 km on a side at the equator (smaller at higher latitudes),
    /// so a typical continent-zoom viewport overlaps 6–20 cells. Smaller
    /// cells make the index bigger without speeding up queries; larger
    /// cells start returning too many false-positives per viewport.
    private static let cellDegrees: Double = 5

    private var byTier: [AirportInfo.Tier: [AirportInfo]] = [:]
    private var grid: [GridKey: [AirportInfo]] = [:]
    private var byIATA: [String: AirportInfo] = [:]
    /// City / municipality (diacritic-folded, lowercased) → its airports.
    /// Used to resolve `weather Munich` → the busiest nearby station.
    private var byMunicipality: [String: [AirportInfo]] = [:]
    private let lock = NSLock()
    private var loaded = false

    private init() {}

    /// All airports inside the given lat/lon bounding box, optionally
    /// restricted to one or more tiers. Crosses the antimeridian
    /// naturally — pass `minLon > maxLon` to wrap.
    public func airports(
        minLat: Double, maxLat: Double,
        minLon: Double, maxLon: Double,
        tiers: Set<AirportInfo.Tier>
    ) -> [AirportInfo] {
        ensureLoaded()
        let wrap = minLon > maxLon

        let cells = wrap
            ? gridCells(minLat: minLat, maxLat: maxLat, minLon: minLon, maxLon: 180)
                + gridCells(minLat: minLat, maxLat: maxLat, minLon: -180, maxLon: maxLon)
            : gridCells(minLat: minLat, maxLat: maxLat, minLon: minLon, maxLon: maxLon)

        var out: [AirportInfo] = []
        out.reserveCapacity(64)
        for cell in cells {
            guard let bucket = grid[cell] else { continue }
            for a in bucket where tiers.contains(a.tier) {
                guard a.latitude >= minLat, a.latitude <= maxLat else { continue }
                if wrap {
                    if !(a.longitude >= minLon || a.longitude <= maxLon) { continue }
                } else {
                    if !(a.longitude >= minLon && a.longitude <= maxLon) { continue }
                }
                out.append(a)
            }
        }
        return out
    }

    /// All airports of a given tier (across the whole world). Used for
    /// the world/continent zoom where viewport culling alone leaves too
    /// many candidates — combined with `tiers: [.large]` this returns
    /// only ~1 200 entries even with no bbox.
    public func airports(tier: AirportInfo.Tier) -> [AirportInfo] {
        ensureLoaded()
        return byTier[tier] ?? []
    }

    /// O(1) lookup by ICAO (or local code if the airport has no ICAO).
    public func airport(forIdent ident: String) -> AirportInfo? {
        ensureLoaded()
        let key = ident.uppercased()
        for tier in AirportInfo.Tier.allCases {
            if let bucket = byTier[tier], let hit = bucket.first(where: { $0.ident == key }) {
                return hit
            }
        }
        return nil
    }

    /// O(1) lookup by 3-letter IATA code (e.g. "MUC" → EDDM).
    public func airport(forIATA iata: String) -> AirportInfo? {
        ensureLoaded()
        return byIATA[iata.uppercased()]
    }

    /// Best airport for a city / place name (e.g. "Munich", "New York").
    /// Matches on municipality, preferring the largest tier so a city with
    /// several fields resolves to its primary airport. Returns nil if no
    /// airport's municipality matches.
    public func airport(matchingPlace place: String) -> AirportInfo? {
        ensureLoaded()
        guard let candidates = byMunicipality[Self.placeKey(place)], !candidates.isEmpty else {
            return nil
        }
        func rank(_ t: AirportInfo.Tier) -> Int {
            switch t { case .large: return 0; case .medium: return 1; case .small: return 2 }
        }
        return candidates.min { rank($0.tier) < rank($1.tier) }
    }

    /// Normalised key for place matching: diacritic-folded + lowercased so
    /// "München" / "Munich" / "munich" all collide sensibly.
    private static func placeKey(_ s: String) -> String {
        s.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US"))
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var entryCount: Int {
        ensureLoaded()
        return byTier.values.reduce(0) { $0 + $1.count }
    }

    // MARK: - Loading

    private func ensureLoaded() {
        lock.lock(); defer { lock.unlock() }
        if loaded { return }
        loaded = true
        guard let url = Bundle.module.url(forResource: "airports", withExtension: "csv"),
              let data = try? Data(contentsOf: url),
              let csv = String(data: data, encoding: .utf8)
        else {
            return
        }
        parse(csv: csv)
    }

    private func parse(csv: String) {
        // CRLF files defeat `String.split(separator: "\n")` because Swift's
        // Character collapses `\r\n` into a single grapheme cluster, so the
        // split never finds a `\n` boundary. Splitting on a CharacterSet
        // works for LF, CRLF, and CR.
        let rawLines = csv.components(separatedBy: .newlines)
        let lines = rawLines.dropFirst().filter { !$0.isEmpty }
        for line in lines {
            let fields = splitCSVRow(line)
            guard fields.count >= 8 else { continue }
            let ident = unquote(fields[0])
            guard !ident.isEmpty else { continue }
            let tier: AirportInfo.Tier
            switch unquote(fields[1]) {
            case "large_airport":  tier = .large
            case "medium_airport": tier = .medium
            case "small_airport":  tier = .small
            default: continue
            }
            guard let lat = Double(unquote(fields[3])),
                  let lon = Double(unquote(fields[4])) else { continue }

            let iata = unquote(fields[5])
            let municipality = unquote(fields[6])
            let country = unquote(fields[7])

            let airport = AirportInfo(
                ident: ident.uppercased(),
                tier: tier,
                name: unquote(fields[2]),
                latitude: lat,
                longitude: lon,
                iata: iata.isEmpty ? nil : iata,
                municipality: municipality.isEmpty ? nil : municipality,
                isoCountry: country.isEmpty ? nil : country
            )

            byTier[tier, default: []].append(airport)
            grid[Self.cellKey(lat: lat, lon: lon), default: []].append(airport)
            if let ia = airport.iata { byIATA[ia.uppercased()] = airport }
            if let m = airport.municipality {
                byMunicipality[Self.placeKey(m), default: []].append(airport)
            }
        }
    }

    // MARK: - Grid index

    private struct GridKey: Hashable {
        let latIndex: Int
        let lonIndex: Int
    }

    private static func cellKey(lat: Double, lon: Double) -> GridKey {
        GridKey(
            latIndex: Int((lat / cellDegrees).rounded(.down)),
            lonIndex: Int((lon / cellDegrees).rounded(.down))
        )
    }

    private func gridCells(minLat: Double, maxLat: Double, minLon: Double, maxLon: Double) -> [GridKey] {
        let latLo = Int((minLat / Self.cellDegrees).rounded(.down))
        let latHi = Int((maxLat / Self.cellDegrees).rounded(.down))
        let lonLo = Int((minLon / Self.cellDegrees).rounded(.down))
        let lonHi = Int((maxLon / Self.cellDegrees).rounded(.down))
        var out: [GridKey] = []
        out.reserveCapacity((latHi - latLo + 1) * (lonHi - lonLo + 1))
        for y in latLo...latHi {
            for x in lonLo...lonHi {
                out.append(GridKey(latIndex: y, lonIndex: x))
            }
        }
        return out
    }

    // MARK: - CSV helpers (lifted from RunwayDatabase — same shape, same caveats)

    private func unquote(_ s: Substring) -> String { unquote(String(s)) }
    private func unquote(_ s: String) -> String {
        var out = s
        if out.hasPrefix("\"") { out = String(out.dropFirst()) }
        if out.hasSuffix("\"") { out = String(out.dropLast()) }
        return out
    }

    private func splitCSVRow(_ row: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        for char in row {
            if char == "\"" {
                inQuotes.toggle()
                current.append(char)
            } else if char == "," && !inQuotes {
                fields.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        fields.append(current)
        return fields
    }
}
