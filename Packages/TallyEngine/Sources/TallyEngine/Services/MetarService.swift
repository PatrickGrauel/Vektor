import Foundation
import TallyAviation

/// Wrapper around aviationweather.gov (METAR / TAF) and datis.clowd.io (ATIS,
/// FAA airports only). All sources are free and unauthenticated.
public actor MetarService {

    public enum ReportKind: String, Codable, Sendable {
        case metar, taf, atis
    }

    public struct Entry: Codable, Sendable {
        public let stationId: String
        public let kind: ReportKind
        public let raw: String
        public let fetchedAt: Date
    }

    /// Process-wide instance. Previously `MetarView` and `MetarCacheBridge`
    /// each spun up their own `MetarService`, which meant two parallel
    /// in-memory caches writing to the same disk file and racing each other.
    /// One shared instance keeps the in-memory state consistent.
    public static let shared = MetarService()

    private let session: URLSession
    private var cache: [String: Entry] = [:]
    private let cacheURL: URL
    /// Interval between background prune sweeps. Short enough that a long-
    /// running session doesn't accumulate hours of stale entries; long
    /// enough that pruning itself is cheap.
    private static let pruneInterval: TimeInterval = 15 * 60
    private var pruningTask: Task<Void, Never>?

    public init(cacheURL: URL? = nil, session: URLSession = .shared) {
        let fm = FileManager.default
        let dir = (try? fm.url(for: .cachesDirectory, in: .userDomainMask,
                               appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.cacheURL = cacheURL ?? dir.appendingPathComponent("metar.cache.json")
        self.session = session
        self.cache = Self.loadFromDisk(at: self.cacheURL)
        // Defer pruning + the pruning loop into a Task to stay Swift 6
        // compliant: actor init runs non-isolated, so we can't call
        // actor-isolated methods directly from it.
        Task { [weak self] in
            await self?.pruneExpired()
            await self?.startPruningLoop()
        }
    }

    deinit {
        pruningTask?.cancel()
    }

    public func metar(for icao: String) async -> Entry? { await fetch(icao: icao, kind: .metar) }
    public func taf(for icao: String)   async -> Entry? { await fetch(icao: icao, kind: .taf) }
    public func atis(for icao: String)  async -> Entry? { await fetch(icao: icao, kind: .atis) }

    private func fetch(icao: String, kind: ReportKind) async -> Entry? {
        let key = "\(kind.rawValue.uppercased())|\(icao.uppercased())"
        if let entry = cache[key] {
            if Date().timeIntervalSince(entry.fetchedAt) > 300 {
                Task { _ = try? await refresh(icao: icao, kind: kind) }
            }
            return entry
        }
        return try? await refresh(icao: icao, kind: kind)
    }

    @discardableResult
    public func refresh(icao: String, kind: ReportKind) async throws -> Entry {
        // Sanitise: only A–Z / 0–9, max 4 chars. Anything else is rejected
        // before it ever reaches a URL builder, so we can't crash on a
        // bogus station code like `"K SFO"` or `"../etc/passwd"`.
        let id = Self.sanitise(icao: icao)
        guard !id.isEmpty else { throw URLError(.badURL) }
        let raw: String
        switch kind {
        case .metar:
            raw = try await fetchRaw(
                "https://aviationweather.gov/api/data/metar?ids=\(id)&format=raw"
            )
        case .taf:
            raw = try await fetchRaw(
                "https://aviationweather.gov/api/data/taf?ids=\(id)&format=raw"
            )
        case .atis:
            raw = try await fetchAtis(id: id)
        }
        let entry = Entry(stationId: id, kind: kind, raw: raw, fetchedAt: Date())
        cache["\(kind.rawValue.uppercased())|\(id)"] = entry
        saveToDisk()
        return entry
    }

    /// Strip anything that isn't a letter or digit, uppercase, then
    /// resolve 3-letter IATA codes to their 4-letter ICAO equivalents so
    /// `MetarService.metar(for: "JFK")` and `for: "KJFK"` both fetch the
    /// same station. Unknown 3-letter inputs return "" (the upstream API
    /// would reject them anyway, but failing fast keeps the cache clean).
    /// Anything longer than 4 chars is truncated to the first 4.
    static func sanitise(icao: String) -> String {
        let cleaned = icao.uppercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }
        let s = String(String.UnicodeScalarView(cleaned))
        if s.count == 3 {
            return AirportCodeMap.icao(forIATA: s) ?? ""
        }
        return String(s.prefix(4))
    }

    private func fetchRaw(_ urlString: String) async throws -> String {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        let (data, _) = try await session.data(from: url)
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// FAA D-ATIS via datis.clowd.io — text-based, FAA airports only. We
    /// deliberately do not attempt to synthesize or guess ATIS for non-FAA
    /// airports: ATIS is safety-relevant, the pilot must consult the real
    /// broadcast.
    private func fetchAtis(id: String) async throws -> String {
        guard let url = URL(string: "https://datis.clowd.io/api/\(id)") else { return "" }
        let (data, _) = try await session.data(from: url)
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return "ATIS unavailable for \(id) (datis.clowd.io covers FAA airports only). Consult the airport's actual ATIS frequency."
        }
        if arr.isEmpty {
            return "No ATIS available for \(id)"
        }
        let lines = arr.compactMap { dict -> String? in
            let code = (dict["code"] as? String) ?? "?"
            let type = (dict["type"] as? String) ?? ""
            let text = (dict["datis"] as? String) ?? ""
            let typeLabel = type.isEmpty ? "" : " (\(type))"
            return "ATIS \(code)\(typeLabel): \(text)"
        }
        return lines.joined(separator: "\n\n")
    }

    // MARK: - Disk cache + pruning

    /// Kicks off a background loop that re-prunes the cache every 15 min.
    /// Without this, `pruneExpired()` only ran at init — meaning a long-
    /// running app accumulated 24h of entries with no further cleanup.
    private func startPruningLoop() {
        pruningTask?.cancel()
        pruningTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.pruneInterval * 1_000_000_000))
                await self?.pruneExpired()
            }
        }
    }

    /// Exposed for tests + the debug "cache size" line in Settings.
    public func entryCount() -> Int { cache.count }

    /// Removes cache entries that are older than 24 hours. For TAFs, also
    /// requires the TAF's validity period to have ended — a stale-but-still-
    /// valid forecast is kept until it expires.
    public func pruneExpired() {
        let now = Date()
        let dayAgo = now.addingTimeInterval(-24 * 3600)
        cache = cache.filter { _, entry in
            switch entry.kind {
            case .metar, .atis:
                return entry.fetchedAt >= dayAgo
            case .taf:
                if entry.fetchedAt >= dayAgo { return true }
                // > 24h old: keep only if its validity hasn't expired yet.
                let decoded = TafParser.parse(entry.raw)
                if let end = decoded.validityEnd, end > now { return true }
                return false
            }
        }
        saveToDisk()
    }

    private static func loadFromDisk(at url: URL) -> [String: Entry] {
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return [:] }
        return dict
    }

    private func saveToDisk() {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }
}
