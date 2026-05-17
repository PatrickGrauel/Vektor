import Foundation
import CoreLocation
#if canImport(Contacts)
import Contacts
#endif

/// Resolves user-entered city / airport / abbreviation strings into a
/// canonical city name + IANA timezone. Two tiers:
///
/// 1. A hand-curated static database of IATA / ICAO airport codes and
///    common city abbreviations (synchronous, instant).
/// 2. `CLGeocoder` for arbitrary city names (asynchronous, cached on
///    disk so repeat lookups are instant on subsequent launches).
///
/// Callers that need sync access (the calculator engine) consult `cached(for:)`
/// first; on a miss, they kick off `resolve(query:)` in a Task and re-evaluate
/// when `Notification.Name.cityResolverUpdated` fires.
public actor CityResolver {

    public struct Resolved: Codable, Sendable, Equatable {
        /// Pretty city name to show users, e.g. "Munich" or "Canggu, Bali".
        public let canonicalName: String
        /// IANA timezone identifier, e.g. "Europe/Berlin".
        public let timezoneId: String
        /// If the user typed an airport / abbreviation, what they typed.
        /// Used to render "Munich (MUC)" style hints.
        public let originalCode: String?
    }

    /// Fires every time the resolver successfully resolves a previously
    /// unknown query. The calculator pane re-evaluates on this.
    public static let notificationName = Notification.Name("tally.cityResolver.updated")

    public static let shared = CityResolver()

    private var dynamicCache: [String: Resolved]
    private let cacheURL: URL

    private init() {
        let fm = FileManager.default
        let dir = (try? fm.url(for: .cachesDirectory, in: .userDomainMask,
                               appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.cacheURL = dir.appendingPathComponent("cityResolver.cache.json")

        var loaded: [String: Resolved] = [:]
        if let data = try? Data(contentsOf: cacheURL),
           let dict = try? JSONDecoder().decode([String: Resolved].self, from: data) {
            loaded = dict
        }
        // Purge entries that would now be shadowed by the static alias table.
        // Earlier versions let CLGeocoder fuzzy-match abbreviations like
        // "Zulu" to similarly-spelled place names ("Zulia, Venezuela") and
        // cached the false hit. The sync resolver now prefers the static
        // alias unconditionally, so those entries are not just unreachable
        // but wrong — wipe them so the on-disk cache heals itself on next
        // launch instead of carrying poison across upgrades.
        let tz = TimezoneBridge()
        let purged = loaded.filter { key, _ in tz.legacyResolveLocal(key) == nil }
        self.dynamicCache = purged
        for (k, v) in purged { Self.synchronousCacheSnapshot.set(k, v) }
        if purged.count != loaded.count,
           let data = try? JSONEncoder().encode(purged) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }

    // MARK: - Public API

    /// Synchronous lookup: returns a hit only if the query is in the static
    /// DB or the in-memory cache populated by a previous resolve.
    public nonisolated func cached(for raw: String) -> Resolved? {
        let key = normalize(raw)
        if let r = AirportDB.lookup(key) { return r }
        return Self.synchronousCacheSnapshot.get(key)
    }

    /// Async lookup: tries static DB → cache → CLGeocoder. Caches on success
    /// and posts a notification so observers can re-evaluate.
    ///
    /// **Never** sends queries that the timezone bridge can resolve via its
    /// static alias table (UTC, Zulu, Z, CET, PST, …) to CLGeocoder.
    /// Without the guard, "Zulu" fuzzy-matches to "Zulia, Venezuela" and
    /// the false hit gets cached on disk — poisoning every subsequent
    /// "Zulu" lookup permanently. The sync resolver already handles
    /// these correctly, so the async path returning nil here is harmless.
    @discardableResult
    public func resolve(query raw: String) async -> Resolved? {
        let key = normalize(raw)
        if let hit = AirportDB.lookup(key) { return hit }
        if let hit = dynamicCache[key] { return hit }

        // Guard against CLGeocoder fuzzy-matching well-known abbreviations
        // to similarly-spelled place names. See doc comment above.
        if TimezoneBridge().legacyResolveLocal(raw) != nil { return nil }

        guard let geo = await geocode(query: raw) else { return nil }
        dynamicCache[key] = geo
        Self.synchronousCacheSnapshot.set(key, geo)
        persistCache()

        await MainActor.run {
            NotificationCenter.default.post(name: Self.notificationName, object: nil)
        }
        return geo
    }

    // MARK: - Internals

    /// Thread-safe mirror of the dynamic cache so nonisolated `cached(for:)`
    /// callers (the calculator engine) can hit it without awaiting the actor.
    private static let synchronousCacheSnapshot = SyncSnapshot()

    private func geocode(query: String) async -> Resolved? {
        let geocoder = CLGeocoder()
        do {
            let placemarks = try await geocoder.geocodeAddressString(query)
            guard let placemark = placemarks.first,
                  let tz = placemark.timeZone else { return nil }
            let parts: [String?] = [
                placemark.locality,
                placemark.subAdministrativeArea,
                placemark.administrativeArea,
            ]
            let nameParts = parts.compactMap { $0 }
            let name: String
            if nameParts.isEmpty {
                name = placemark.name ?? query
            } else if nameParts.count > 1 {
                name = "\(nameParts[0]), \(nameParts.dropFirst().joined(separator: ", "))"
            } else {
                name = nameParts[0]
            }
            return Resolved(canonicalName: name, timezoneId: tz.identifier, originalCode: nil)
        } catch {
            return nil
        }
    }

    private func persistCache() {
        guard let data = try? JSONEncoder().encode(dynamicCache) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    private nonisolated func normalize(_ raw: String) -> String {
        raw.replacingOccurrences(of: "time", with: "", options: .caseInsensitive)
           .replacingOccurrences(of: "in ", with: "", options: .caseInsensitive)
           .trimmingCharacters(in: .whitespacesAndNewlines)
           .uppercased()
    }
}

private final class SyncSnapshot: @unchecked Sendable {
    private var dict: [String: CityResolver.Resolved] = [:]
    private let lock = NSLock()

    func get(_ key: String) -> CityResolver.Resolved? {
        lock.lock(); defer { lock.unlock() }
        return dict[key]
    }

    func set(_ key: String, _ value: CityResolver.Resolved) {
        lock.lock(); defer { lock.unlock() }
        dict[key] = value
    }
}

// MARK: - Static airport / abbreviation DB

private enum AirportDB {

    /// Lookup by IATA (3-letter), ICAO (4-letter), or city name.
    /// All inputs are pre-uppercased.
    static func lookup(_ key: String) -> CityResolver.Resolved? {
        if let r = byIATA[key] {
            return .init(canonicalName: r.city, timezoneId: r.tz, originalCode: key)
        }
        if let r = byICAO[key] {
            return .init(canonicalName: r.city, timezoneId: r.tz, originalCode: key)
        }
        // Common city names (uppercased)
        if let tz = cityNames[key] {
            return .init(canonicalName: key.capitalized, timezoneId: tz, originalCode: nil)
        }
        return nil
    }

    private struct Entry { let city: String; let tz: String }

    /// Major international airports keyed by IATA code.
    private static let byIATA: [String: Entry] = [
        // North America
        "JFK": .init(city: "New York", tz: "America/New_York"),
        "LGA": .init(city: "New York", tz: "America/New_York"),
        "EWR": .init(city: "Newark", tz: "America/New_York"),
        "BOS": .init(city: "Boston", tz: "America/New_York"),
        "DCA": .init(city: "Washington", tz: "America/New_York"),
        "IAD": .init(city: "Washington Dulles", tz: "America/New_York"),
        "ATL": .init(city: "Atlanta", tz: "America/New_York"),
        "MIA": .init(city: "Miami", tz: "America/New_York"),
        "MCO": .init(city: "Orlando", tz: "America/New_York"),
        "ORD": .init(city: "Chicago", tz: "America/Chicago"),
        "MDW": .init(city: "Chicago Midway", tz: "America/Chicago"),
        "DFW": .init(city: "Dallas/Fort Worth", tz: "America/Chicago"),
        "IAH": .init(city: "Houston", tz: "America/Chicago"),
        "AUS": .init(city: "Austin", tz: "America/Chicago"),
        "MSP": .init(city: "Minneapolis", tz: "America/Chicago"),
        "DEN": .init(city: "Denver", tz: "America/Denver"),
        "PHX": .init(city: "Phoenix", tz: "America/Phoenix"),
        "LAS": .init(city: "Las Vegas", tz: "America/Los_Angeles"),
        "LAX": .init(city: "Los Angeles", tz: "America/Los_Angeles"),
        "SFO": .init(city: "San Francisco", tz: "America/Los_Angeles"),
        "OAK": .init(city: "Oakland", tz: "America/Los_Angeles"),
        "SJC": .init(city: "San Jose", tz: "America/Los_Angeles"),
        "SAN": .init(city: "San Diego", tz: "America/Los_Angeles"),
        "SEA": .init(city: "Seattle", tz: "America/Los_Angeles"),
        "PDX": .init(city: "Portland", tz: "America/Los_Angeles"),
        "ANC": .init(city: "Anchorage", tz: "America/Anchorage"),
        "HNL": .init(city: "Honolulu", tz: "Pacific/Honolulu"),
        "YYZ": .init(city: "Toronto", tz: "America/Toronto"),
        "YUL": .init(city: "Montréal", tz: "America/Toronto"),
        "YVR": .init(city: "Vancouver", tz: "America/Vancouver"),
        "MEX": .init(city: "Mexico City", tz: "America/Mexico_City"),
        // Caribbean / Central America
        "SJU": .init(city: "San Juan", tz: "America/Puerto_Rico"),
        "PUJ": .init(city: "Punta Cana", tz: "America/Santo_Domingo"),
        "MBJ": .init(city: "Montego Bay", tz: "America/Jamaica"),
        "NAS": .init(city: "Nassau", tz: "America/Nassau"),
        "CUN": .init(city: "Cancún", tz: "America/Cancun"),
        // South America
        "GRU": .init(city: "São Paulo", tz: "America/Sao_Paulo"),
        "GIG": .init(city: "Rio de Janeiro", tz: "America/Sao_Paulo"),
        "EZE": .init(city: "Buenos Aires", tz: "America/Argentina/Buenos_Aires"),
        "SCL": .init(city: "Santiago", tz: "America/Santiago"),
        "LIM": .init(city: "Lima", tz: "America/Lima"),
        "BOG": .init(city: "Bogotá", tz: "America/Bogota"),
        "UIO": .init(city: "Quito", tz: "America/Guayaquil"),
        "CCS": .init(city: "Caracas", tz: "America/Caracas"),
        // UK / Ireland
        "LHR": .init(city: "London Heathrow", tz: "Europe/London"),
        "LGW": .init(city: "London Gatwick", tz: "Europe/London"),
        "STN": .init(city: "London Stansted", tz: "Europe/London"),
        "LTN": .init(city: "London Luton", tz: "Europe/London"),
        "LCY": .init(city: "London City", tz: "Europe/London"),
        "MAN": .init(city: "Manchester", tz: "Europe/London"),
        "EDI": .init(city: "Edinburgh", tz: "Europe/London"),
        "GLA": .init(city: "Glasgow", tz: "Europe/London"),
        "BHX": .init(city: "Birmingham", tz: "Europe/London"),
        "DUB": .init(city: "Dublin", tz: "Europe/Dublin"),
        // Continental Europe
        "CDG": .init(city: "Paris CDG", tz: "Europe/Paris"),
        "ORY": .init(city: "Paris Orly", tz: "Europe/Paris"),
        "NCE": .init(city: "Nice", tz: "Europe/Paris"),
        "MRS": .init(city: "Marseille", tz: "Europe/Paris"),
        "LYS": .init(city: "Lyon", tz: "Europe/Paris"),
        "AMS": .init(city: "Amsterdam", tz: "Europe/Amsterdam"),
        "BRU": .init(city: "Brussels", tz: "Europe/Brussels"),
        "FRA": .init(city: "Frankfurt", tz: "Europe/Berlin"),
        "MUC": .init(city: "Munich", tz: "Europe/Berlin"),
        "BER": .init(city: "Berlin", tz: "Europe/Berlin"),
        "HAM": .init(city: "Hamburg", tz: "Europe/Berlin"),
        "DUS": .init(city: "Düsseldorf", tz: "Europe/Berlin"),
        "STR": .init(city: "Stuttgart", tz: "Europe/Berlin"),
        "CGN": .init(city: "Cologne", tz: "Europe/Berlin"),
        "VIE": .init(city: "Vienna", tz: "Europe/Vienna"),
        "ZRH": .init(city: "Zurich", tz: "Europe/Zurich"),
        "GVA": .init(city: "Geneva", tz: "Europe/Zurich"),
        "MAD": .init(city: "Madrid", tz: "Europe/Madrid"),
        "BCN": .init(city: "Barcelona", tz: "Europe/Madrid"),
        "PMI": .init(city: "Palma de Mallorca", tz: "Europe/Madrid"),
        "LIS": .init(city: "Lisbon", tz: "Europe/Lisbon"),
        "OPO": .init(city: "Porto", tz: "Europe/Lisbon"),
        "FCO": .init(city: "Rome FCO", tz: "Europe/Rome"),
        "CIA": .init(city: "Rome Ciampino", tz: "Europe/Rome"),
        "MXP": .init(city: "Milan Malpensa", tz: "Europe/Rome"),
        "LIN": .init(city: "Milan Linate", tz: "Europe/Rome"),
        "VCE": .init(city: "Venice", tz: "Europe/Rome"),
        "NAP": .init(city: "Naples", tz: "Europe/Rome"),
        "ATH": .init(city: "Athens", tz: "Europe/Athens"),
        "SOF": .init(city: "Sofia", tz: "Europe/Sofia"),
        "BUD": .init(city: "Budapest", tz: "Europe/Budapest"),
        "PRG": .init(city: "Prague", tz: "Europe/Prague"),
        "WAW": .init(city: "Warsaw", tz: "Europe/Warsaw"),
        "KRK": .init(city: "Kraków", tz: "Europe/Warsaw"),
        "CPH": .init(city: "Copenhagen", tz: "Europe/Copenhagen"),
        "OSL": .init(city: "Oslo", tz: "Europe/Oslo"),
        "ARN": .init(city: "Stockholm", tz: "Europe/Stockholm"),
        "HEL": .init(city: "Helsinki", tz: "Europe/Helsinki"),
        "KEF": .init(city: "Reykjavík", tz: "Atlantic/Reykjavik"),
        "RIX": .init(city: "Riga", tz: "Europe/Riga"),
        "TLL": .init(city: "Tallinn", tz: "Europe/Tallinn"),
        "VNO": .init(city: "Vilnius", tz: "Europe/Vilnius"),
        "OTP": .init(city: "Bucharest", tz: "Europe/Bucharest"),
        "BEG": .init(city: "Belgrade", tz: "Europe/Belgrade"),
        "ZAG": .init(city: "Zagreb", tz: "Europe/Zagreb"),
        "LJU": .init(city: "Ljubljana", tz: "Europe/Ljubljana"),
        "IST": .init(city: "Istanbul", tz: "Europe/Istanbul"),
        "SAW": .init(city: "Istanbul Sabiha", tz: "Europe/Istanbul"),
        "ESB": .init(city: "Ankara", tz: "Europe/Istanbul"),
        "AYT": .init(city: "Antalya", tz: "Europe/Istanbul"),
        "SVO": .init(city: "Moscow SVO", tz: "Europe/Moscow"),
        "DME": .init(city: "Moscow DME", tz: "Europe/Moscow"),
        "LED": .init(city: "St Petersburg", tz: "Europe/Moscow"),
        "KBP": .init(city: "Kyiv", tz: "Europe/Kyiv"),
        // Middle East / Africa
        "DXB": .init(city: "Dubai", tz: "Asia/Dubai"),
        "AUH": .init(city: "Abu Dhabi", tz: "Asia/Dubai"),
        "DOH": .init(city: "Doha", tz: "Asia/Qatar"),
        "RUH": .init(city: "Riyadh", tz: "Asia/Riyadh"),
        "JED": .init(city: "Jeddah", tz: "Asia/Riyadh"),
        "TLV": .init(city: "Tel Aviv", tz: "Asia/Jerusalem"),
        "AMM": .init(city: "Amman", tz: "Asia/Amman"),
        "BEY": .init(city: "Beirut", tz: "Asia/Beirut"),
        "BAH": .init(city: "Bahrain", tz: "Asia/Bahrain"),
        "KWI": .init(city: "Kuwait City", tz: "Asia/Kuwait"),
        "MCT": .init(city: "Muscat", tz: "Asia/Muscat"),
        "CAI": .init(city: "Cairo", tz: "Africa/Cairo"),
        "JNB": .init(city: "Johannesburg", tz: "Africa/Johannesburg"),
        "CPT": .init(city: "Cape Town", tz: "Africa/Johannesburg"),
        "ADD": .init(city: "Addis Ababa", tz: "Africa/Addis_Ababa"),
        "NBO": .init(city: "Nairobi", tz: "Africa/Nairobi"),
        "LOS": .init(city: "Lagos", tz: "Africa/Lagos"),
        "CMN": .init(city: "Casablanca", tz: "Africa/Casablanca"),
        // Asia
        "DEL": .init(city: "Delhi", tz: "Asia/Kolkata"),
        "BOM": .init(city: "Mumbai", tz: "Asia/Kolkata"),
        "BLR": .init(city: "Bengaluru", tz: "Asia/Kolkata"),
        "MAA": .init(city: "Chennai", tz: "Asia/Kolkata"),
        "HYD": .init(city: "Hyderabad", tz: "Asia/Kolkata"),
        "CCU": .init(city: "Kolkata", tz: "Asia/Kolkata"),
        "GOI": .init(city: "Goa", tz: "Asia/Kolkata"),
        "CMB": .init(city: "Colombo", tz: "Asia/Colombo"),
        "MLE": .init(city: "Malé", tz: "Indian/Maldives"),
        "KTM": .init(city: "Kathmandu", tz: "Asia/Kathmandu"),
        "DAC": .init(city: "Dhaka", tz: "Asia/Dhaka"),
        "ISB": .init(city: "Islamabad", tz: "Asia/Karachi"),
        "KHI": .init(city: "Karachi", tz: "Asia/Karachi"),
        "LHE": .init(city: "Lahore", tz: "Asia/Karachi"),
        "KBL": .init(city: "Kabul", tz: "Asia/Kabul"),
        "BKK": .init(city: "Bangkok", tz: "Asia/Bangkok"),
        "HKT": .init(city: "Phuket", tz: "Asia/Bangkok"),
        "CNX": .init(city: "Chiang Mai", tz: "Asia/Bangkok"),
        "SGN": .init(city: "Ho Chi Minh City", tz: "Asia/Ho_Chi_Minh"),
        "HAN": .init(city: "Hanoi", tz: "Asia/Ho_Chi_Minh"),
        "PNH": .init(city: "Phnom Penh", tz: "Asia/Phnom_Penh"),
        "REP": .init(city: "Siem Reap", tz: "Asia/Phnom_Penh"),
        "VTE": .init(city: "Vientiane", tz: "Asia/Vientiane"),
        "RGN": .init(city: "Yangon", tz: "Asia/Yangon"),
        "SIN": .init(city: "Singapore", tz: "Asia/Singapore"),
        "KUL": .init(city: "Kuala Lumpur", tz: "Asia/Kuala_Lumpur"),
        "PEN": .init(city: "Penang", tz: "Asia/Kuala_Lumpur"),
        "CGK": .init(city: "Jakarta", tz: "Asia/Jakarta"),
        "DPS": .init(city: "Denpasar (Bali)", tz: "Asia/Makassar"),
        "MNL": .init(city: "Manila", tz: "Asia/Manila"),
        "CEB": .init(city: "Cebu", tz: "Asia/Manila"),
        "HKG": .init(city: "Hong Kong", tz: "Asia/Hong_Kong"),
        "MFM": .init(city: "Macau", tz: "Asia/Macau"),
        "TPE": .init(city: "Taipei", tz: "Asia/Taipei"),
        "ICN": .init(city: "Seoul Incheon", tz: "Asia/Seoul"),
        "GMP": .init(city: "Seoul Gimpo", tz: "Asia/Seoul"),
        "PUS": .init(city: "Busan", tz: "Asia/Seoul"),
        "NRT": .init(city: "Tokyo Narita", tz: "Asia/Tokyo"),
        "HND": .init(city: "Tokyo Haneda", tz: "Asia/Tokyo"),
        "KIX": .init(city: "Osaka", tz: "Asia/Tokyo"),
        "ITM": .init(city: "Osaka Itami", tz: "Asia/Tokyo"),
        "FUK": .init(city: "Fukuoka", tz: "Asia/Tokyo"),
        "CTS": .init(city: "Sapporo", tz: "Asia/Tokyo"),
        "OKA": .init(city: "Okinawa", tz: "Asia/Tokyo"),
        "PEK": .init(city: "Beijing PEK", tz: "Asia/Shanghai"),
        "PKX": .init(city: "Beijing Daxing", tz: "Asia/Shanghai"),
        "PVG": .init(city: "Shanghai Pudong", tz: "Asia/Shanghai"),
        "SHA": .init(city: "Shanghai Hongqiao", tz: "Asia/Shanghai"),
        "CAN": .init(city: "Guangzhou", tz: "Asia/Shanghai"),
        "SZX": .init(city: "Shenzhen", tz: "Asia/Shanghai"),
        "CTU": .init(city: "Chengdu", tz: "Asia/Shanghai"),
        "ULN": .init(city: "Ulaanbaatar", tz: "Asia/Ulaanbaatar"),
        "TAS": .init(city: "Tashkent", tz: "Asia/Tashkent"),
        "ALA": .init(city: "Almaty", tz: "Asia/Almaty"),
        "GYD": .init(city: "Baku", tz: "Asia/Baku"),
        "TBS": .init(city: "Tbilisi", tz: "Asia/Tbilisi"),
        "EVN": .init(city: "Yerevan", tz: "Asia/Yerevan"),
        // Oceania
        "SYD": .init(city: "Sydney", tz: "Australia/Sydney"),
        "MEL": .init(city: "Melbourne", tz: "Australia/Melbourne"),
        "BNE": .init(city: "Brisbane", tz: "Australia/Brisbane"),
        "PER": .init(city: "Perth", tz: "Australia/Perth"),
        "ADL": .init(city: "Adelaide", tz: "Australia/Adelaide"),
        "OOL": .init(city: "Gold Coast", tz: "Australia/Brisbane"),
        "CNS": .init(city: "Cairns", tz: "Australia/Brisbane"),
        "DRW": .init(city: "Darwin", tz: "Australia/Darwin"),
        "AKL": .init(city: "Auckland", tz: "Pacific/Auckland"),
        "WLG": .init(city: "Wellington", tz: "Pacific/Auckland"),
        "CHC": .init(city: "Christchurch", tz: "Pacific/Auckland"),
        "NAN": .init(city: "Nadi", tz: "Pacific/Fiji"),
        "PPT": .init(city: "Papeete", tz: "Pacific/Tahiti"),
    ]

    /// ICAO equivalents for the most-trafficked airports in `byIATA`.
    private static let byICAO: [String: Entry] = [
        "KJFK": .init(city: "New York", tz: "America/New_York"),
        "KLGA": .init(city: "New York", tz: "America/New_York"),
        "KEWR": .init(city: "Newark", tz: "America/New_York"),
        "KBOS": .init(city: "Boston", tz: "America/New_York"),
        "KATL": .init(city: "Atlanta", tz: "America/New_York"),
        "KMIA": .init(city: "Miami", tz: "America/New_York"),
        "KORD": .init(city: "Chicago", tz: "America/Chicago"),
        "KDFW": .init(city: "Dallas/Fort Worth", tz: "America/Chicago"),
        "KIAH": .init(city: "Houston", tz: "America/Chicago"),
        "KDEN": .init(city: "Denver", tz: "America/Denver"),
        "KLAS": .init(city: "Las Vegas", tz: "America/Los_Angeles"),
        "KLAX": .init(city: "Los Angeles", tz: "America/Los_Angeles"),
        "KSFO": .init(city: "San Francisco", tz: "America/Los_Angeles"),
        "KSEA": .init(city: "Seattle", tz: "America/Los_Angeles"),
        "PANC": .init(city: "Anchorage", tz: "America/Anchorage"),
        "PHNL": .init(city: "Honolulu", tz: "Pacific/Honolulu"),
        "CYYZ": .init(city: "Toronto", tz: "America/Toronto"),
        "CYUL": .init(city: "Montréal", tz: "America/Toronto"),
        "CYVR": .init(city: "Vancouver", tz: "America/Vancouver"),
        "MMMX": .init(city: "Mexico City", tz: "America/Mexico_City"),
        "SBGR": .init(city: "São Paulo", tz: "America/Sao_Paulo"),
        "SAEZ": .init(city: "Buenos Aires", tz: "America/Argentina/Buenos_Aires"),
        "EGLL": .init(city: "London Heathrow", tz: "Europe/London"),
        "EGKK": .init(city: "London Gatwick", tz: "Europe/London"),
        "EGCC": .init(city: "Manchester", tz: "Europe/London"),
        "EIDW": .init(city: "Dublin", tz: "Europe/Dublin"),
        "LFPG": .init(city: "Paris CDG", tz: "Europe/Paris"),
        "LFPO": .init(city: "Paris Orly", tz: "Europe/Paris"),
        "EHAM": .init(city: "Amsterdam", tz: "Europe/Amsterdam"),
        "EBBR": .init(city: "Brussels", tz: "Europe/Brussels"),
        "EDDF": .init(city: "Frankfurt", tz: "Europe/Berlin"),
        "EDDM": .init(city: "Munich", tz: "Europe/Berlin"),
        "EDDB": .init(city: "Berlin", tz: "Europe/Berlin"),
        "EDDH": .init(city: "Hamburg", tz: "Europe/Berlin"),
        "LOWW": .init(city: "Vienna", tz: "Europe/Vienna"),
        "LSZH": .init(city: "Zurich", tz: "Europe/Zurich"),
        "LSGG": .init(city: "Geneva", tz: "Europe/Zurich"),
        "LEMD": .init(city: "Madrid", tz: "Europe/Madrid"),
        "LEBL": .init(city: "Barcelona", tz: "Europe/Madrid"),
        "LPPT": .init(city: "Lisbon", tz: "Europe/Lisbon"),
        "LIRF": .init(city: "Rome FCO", tz: "Europe/Rome"),
        "LIMC": .init(city: "Milan Malpensa", tz: "Europe/Rome"),
        "LGAV": .init(city: "Athens", tz: "Europe/Athens"),
        "LKPR": .init(city: "Prague", tz: "Europe/Prague"),
        "EPWA": .init(city: "Warsaw", tz: "Europe/Warsaw"),
        "EKCH": .init(city: "Copenhagen", tz: "Europe/Copenhagen"),
        "ENGM": .init(city: "Oslo", tz: "Europe/Oslo"),
        "ESSA": .init(city: "Stockholm", tz: "Europe/Stockholm"),
        "EFHK": .init(city: "Helsinki", tz: "Europe/Helsinki"),
        "BIKF": .init(city: "Reykjavík", tz: "Atlantic/Reykjavik"),
        "LTBA": .init(city: "Istanbul", tz: "Europe/Istanbul"),
        "LTFM": .init(city: "Istanbul", tz: "Europe/Istanbul"),
        "UUDD": .init(city: "Moscow DME", tz: "Europe/Moscow"),
        "UUEE": .init(city: "Moscow SVO", tz: "Europe/Moscow"),
        "OMDB": .init(city: "Dubai", tz: "Asia/Dubai"),
        "OMAA": .init(city: "Abu Dhabi", tz: "Asia/Dubai"),
        "OTHH": .init(city: "Doha", tz: "Asia/Qatar"),
        "OERK": .init(city: "Riyadh", tz: "Asia/Riyadh"),
        "OEJN": .init(city: "Jeddah", tz: "Asia/Riyadh"),
        "LLBG": .init(city: "Tel Aviv", tz: "Asia/Jerusalem"),
        "HECA": .init(city: "Cairo", tz: "Africa/Cairo"),
        "FAOR": .init(city: "Johannesburg", tz: "Africa/Johannesburg"),
        "FACT": .init(city: "Cape Town", tz: "Africa/Johannesburg"),
        "HKJK": .init(city: "Nairobi", tz: "Africa/Nairobi"),
        "DNMM": .init(city: "Lagos", tz: "Africa/Lagos"),
        "VIDP": .init(city: "Delhi", tz: "Asia/Kolkata"),
        "VABB": .init(city: "Mumbai", tz: "Asia/Kolkata"),
        "VOBL": .init(city: "Bengaluru", tz: "Asia/Kolkata"),
        "OPKC": .init(city: "Karachi", tz: "Asia/Karachi"),
        "OPLA": .init(city: "Lahore", tz: "Asia/Karachi"),
        "VTBS": .init(city: "Bangkok", tz: "Asia/Bangkok"),
        "VTSP": .init(city: "Phuket", tz: "Asia/Bangkok"),
        "VVTS": .init(city: "Ho Chi Minh City", tz: "Asia/Ho_Chi_Minh"),
        "VVNB": .init(city: "Hanoi", tz: "Asia/Ho_Chi_Minh"),
        "WSSS": .init(city: "Singapore", tz: "Asia/Singapore"),
        "WMKK": .init(city: "Kuala Lumpur", tz: "Asia/Kuala_Lumpur"),
        "WIII": .init(city: "Jakarta", tz: "Asia/Jakarta"),
        "WADD": .init(city: "Denpasar (Bali)", tz: "Asia/Makassar"),
        "RPLL": .init(city: "Manila", tz: "Asia/Manila"),
        "VHHH": .init(city: "Hong Kong", tz: "Asia/Hong_Kong"),
        "RCTP": .init(city: "Taipei", tz: "Asia/Taipei"),
        "RKSI": .init(city: "Seoul Incheon", tz: "Asia/Seoul"),
        "RJAA": .init(city: "Tokyo Narita", tz: "Asia/Tokyo"),
        "RJTT": .init(city: "Tokyo Haneda", tz: "Asia/Tokyo"),
        "RJBB": .init(city: "Osaka", tz: "Asia/Tokyo"),
        "RJFF": .init(city: "Fukuoka", tz: "Asia/Tokyo"),
        "ZBAA": .init(city: "Beijing", tz: "Asia/Shanghai"),
        "ZBAD": .init(city: "Beijing Daxing", tz: "Asia/Shanghai"),
        "ZSPD": .init(city: "Shanghai Pudong", tz: "Asia/Shanghai"),
        "ZGSZ": .init(city: "Shenzhen", tz: "Asia/Shanghai"),
        "YSSY": .init(city: "Sydney", tz: "Australia/Sydney"),
        "YMML": .init(city: "Melbourne", tz: "Australia/Melbourne"),
        "YBBN": .init(city: "Brisbane", tz: "Australia/Brisbane"),
        "YPPH": .init(city: "Perth", tz: "Australia/Perth"),
        "NZAA": .init(city: "Auckland", tz: "Pacific/Auckland"),
    ]

    /// City name fast-path. Lowercased; we uppercase the lookup key.
    /// (CLGeocoder handles arbitrary city names; this is just for snappy
    /// resolution of household names without a network hit.)
    private static let cityNames: [String: String] = [
        "NEW YORK": "America/New_York",
        "LOS ANGELES": "America/Los_Angeles",
        "CHICAGO": "America/Chicago",
        "DENVER": "America/Denver",
        "MIAMI": "America/New_York",
        "SAN FRANCISCO": "America/Los_Angeles",
        "TORONTO": "America/Toronto",
        "MEXICO CITY": "America/Mexico_City",
        "LONDON": "Europe/London",
        "PARIS": "Europe/Paris",
        "BERLIN": "Europe/Berlin",
        "MUNICH": "Europe/Berlin",
        "FRANKFURT": "Europe/Berlin",
        "HAMBURG": "Europe/Berlin",
        "COLOGNE": "Europe/Berlin",
        "VIENNA": "Europe/Vienna",
        "ZURICH": "Europe/Zurich",
        "GENEVA": "Europe/Zurich",
        "AMSTERDAM": "Europe/Amsterdam",
        "BRUSSELS": "Europe/Brussels",
        "MADRID": "Europe/Madrid",
        "BARCELONA": "Europe/Madrid",
        "LISBON": "Europe/Lisbon",
        "ROME": "Europe/Rome",
        "MILAN": "Europe/Rome",
        "ATHENS": "Europe/Athens",
        "PRAGUE": "Europe/Prague",
        "WARSAW": "Europe/Warsaw",
        "COPENHAGEN": "Europe/Copenhagen",
        "OSLO": "Europe/Oslo",
        "STOCKHOLM": "Europe/Stockholm",
        "HELSINKI": "Europe/Helsinki",
        "REYKJAVIK": "Atlantic/Reykjavik",
        "MOSCOW": "Europe/Moscow",
        "ISTANBUL": "Europe/Istanbul",
        "DUBAI": "Asia/Dubai",
        "DOHA": "Asia/Qatar",
        "TEL AVIV": "Asia/Jerusalem",
        "CAIRO": "Africa/Cairo",
        "JOHANNESBURG": "Africa/Johannesburg",
        "CAPE TOWN": "Africa/Johannesburg",
        "MUMBAI": "Asia/Kolkata",
        "DELHI": "Asia/Kolkata",
        "BANGKOK": "Asia/Bangkok",
        "SINGAPORE": "Asia/Singapore",
        "JAKARTA": "Asia/Jakarta",
        "BALI": "Asia/Makassar",
        "DENPASAR": "Asia/Makassar",
        "CANGGU": "Asia/Makassar",
        "UBUD": "Asia/Makassar",
        "SEMINYAK": "Asia/Makassar",
        "KUTA": "Asia/Makassar",
        "MANILA": "Asia/Manila",
        "HONG KONG": "Asia/Hong_Kong",
        "TAIPEI": "Asia/Taipei",
        "SEOUL": "Asia/Seoul",
        "TOKYO": "Asia/Tokyo",
        "OSAKA": "Asia/Tokyo",
        "KYOTO": "Asia/Tokyo",
        "BEIJING": "Asia/Shanghai",
        "SHANGHAI": "Asia/Shanghai",
        "SYDNEY": "Australia/Sydney",
        "MELBOURNE": "Australia/Melbourne",
        "BRISBANE": "Australia/Brisbane",
        "PERTH": "Australia/Perth",
        "AUCKLAND": "Pacific/Auckland",
        "HONOLULU": "Pacific/Honolulu",
    ]
}
