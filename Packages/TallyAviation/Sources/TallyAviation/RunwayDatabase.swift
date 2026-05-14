import Foundation

/// One physical runway, both ends. Data sourced from OurAirports
/// (`runways.csv`, public-domain) bundled inside TallyAviation.
public struct RunwayInfo: Sendable, Equatable {
    /// Low-end designator — the runway number used when landing on the
    /// low-heading end. Example: "07" or "07L".
    public let leIdent: String
    /// True (geographic) heading of the low end, in degrees. The
    /// runway *designator* is the magnetic heading rounded to the
    /// nearest 10° — derive that separately if you need it, since the
    /// magnetic / true offset varies by location and drifts over time.
    public let leHeadingTrue: Double
    public let leLatitude: Double?
    public let leLongitude: Double?
    public let leElevationFt: Int?

    /// High-end designator. Always 180° opposite the low end.
    public let heIdent: String
    public let heHeadingTrue: Double
    public let heLatitude: Double?
    public let heLongitude: Double?
    public let heElevationFt: Int?

    public let lengthFt: Int?
    public let widthFt: Int?
    /// Free-text surface code as published by OurAirports: ASPH, CON,
    /// GRS, GRVL, TURF, DIRT, WATER, SNOW, ASP-G (asphalt, good
    /// condition), and several dozen others.
    public let surface: String?
    public let lighted: Bool
    public let closed: Bool

    public var lengthMeters: Int? {
        guard let lengthFt else { return nil }
        return Int((Double(lengthFt) * 0.3048).rounded())
    }
    public var widthMeters: Int? {
        guard let widthFt else { return nil }
        return Int((Double(widthFt) * 0.3048).rounded())
    }
}

/// Process-wide runway database. Lazy-loaded on first query, parses
/// the bundled `runways.csv` (~80 000 runways worldwide). All
/// subsequent lookups are O(1) on the ICAO key.
///
/// The CSV is a 28-day snapshot from OurAirports
/// (https://ourairports.com/data/) at build time. To refresh, replace
/// `Resources/runways.csv` and rebuild — there is no runtime fetch.
public final class RunwayDatabase: @unchecked Sendable {

    public static let shared = RunwayDatabase()

    private var byICAO: [String: [RunwayInfo]] = [:]
    private let lock = NSLock()
    private var loaded = false

    private init() {}

    public func runways(forICAO icao: String) -> [RunwayInfo] {
        ensureLoaded()
        return byICAO[icao.uppercased()] ?? []
    }

    /// Approximate airport reference point — the lat/lon of the first
    /// runway threshold we have for this ICAO. For distance / bearing
    /// math between airports this is well within 1 NM of the true ARP
    /// at every airport, which is plenty.
    ///
    /// Returns `nil` when the ICAO isn't in OurAirports, or when none
    /// of its runways carry usable threshold coordinates.
    public func coordinate(forICAO icao: String) -> (latitude: Double, longitude: Double)? {
        ensureLoaded()
        guard let runways = byICAO[icao.uppercased()] else { return nil }
        for r in runways {
            if let lat = r.leLatitude, let lon = r.leLongitude {
                return (lat, lon)
            }
            if let lat = r.heLatitude, let lon = r.heLongitude {
                return (lat, lon)
            }
        }
        return nil
    }

    /// Total number of (airport, runway) rows. Exposed for the
    /// Settings diagnostics line and for tests.
    public var entryCount: Int {
        ensureLoaded()
        return byICAO.values.reduce(0) { $0 + $1.count }
    }

    // MARK: - Loading

    private func ensureLoaded() {
        lock.lock(); defer { lock.unlock() }
        if loaded { return }
        loaded = true
        guard let url = Bundle.module.url(forResource: "runways", withExtension: "csv"),
              let data = try? Data(contentsOf: url),
              let csv = String(data: data, encoding: .utf8)
        else {
            return
        }
        parse(csv: csv)
    }

    private func parse(csv: String) {
        // Skip header.
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: true).dropFirst()
        for line in lines {
            let fields = splitCSVRow(String(line))
            guard fields.count >= 19 else { continue }
            let icao = unquote(fields[2])
            guard !icao.isEmpty else { continue }

            let leHeading = Double(unquote(fields[12])) ?? .nan
            let heHeading = Double(unquote(fields[18])) ?? .nan
            // A row with no usable heading on either end isn't useful
            // for any of Tally's runway-aware features — skip it.
            if leHeading.isNaN && heHeading.isNaN {
                continue
            }

            let runway = RunwayInfo(
                leIdent: unquote(fields[8]),
                leHeadingTrue: leHeading.isNaN ? Self.derivedOpposite(of: heHeading) : leHeading,
                leLatitude: Double(unquote(fields[9])),
                leLongitude: Double(unquote(fields[10])),
                leElevationFt: Int(unquote(fields[11])),
                heIdent: unquote(fields[14]),
                heHeadingTrue: heHeading.isNaN ? Self.derivedOpposite(of: leHeading) : heHeading,
                heLatitude: Double(unquote(fields[15])),
                heLongitude: Double(unquote(fields[16])),
                heElevationFt: Int(unquote(fields[17])),
                lengthFt: Int(unquote(fields[3])),
                widthFt: Int(unquote(fields[4])),
                surface: {
                    let s = unquote(fields[5])
                    return s.isEmpty ? nil : s
                }(),
                lighted: unquote(fields[6]) == "1",
                closed: unquote(fields[7]) == "1"
            )
            byICAO[icao.uppercased(), default: []].append(runway)
        }
    }

    /// 180°-opposite, normalised to [0, 360).
    private static func derivedOpposite(of heading: Double) -> Double {
        let opposite = heading + 180
        return opposite.truncatingRemainder(dividingBy: 360)
    }

    // MARK: - CSV helpers

    private func unquote(_ s: Substring) -> String { unquote(String(s)) }
    private func unquote(_ s: String) -> String {
        var out = s
        if out.hasPrefix("\"") { out = String(out.dropFirst()) }
        if out.hasSuffix("\"") { out = String(out.dropLast()) }
        return out
    }

    /// Simple CSV row splitter that respects double-quoted fields with
    /// embedded commas. Doesn't handle escaped quotes (`""`) since the
    /// OurAirports runway file doesn't use them.
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
