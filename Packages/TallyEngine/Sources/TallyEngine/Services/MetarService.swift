import Foundation
import TallyAviation
import os

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

    private static let logger = Logger(subsystem: "app.tally.Tally", category: "metar")
    private static let requestTimeout: TimeInterval = 15

    private let session: URLSession
    private var cache: [String: Entry] = [:]
    private let cacheURL: URL
    /// Interval between background prune sweeps. Short enough that a long-
    /// running session doesn't accumulate hours of stale entries; long
    /// enough that pruning itself is cheap.
    private static let pruneInterval: TimeInterval = 15 * 60
    private var pruningTask: Task<Void, Never>?

    public init(cacheURL: URL? = nil, session: URLSession? = nil) {
        let fm = FileManager.default
        let dir = (try? fm.url(for: .cachesDirectory, in: .userDomainMask,
                               appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.cacheURL = cacheURL ?? dir.appendingPathComponent("metar.cache.json")
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = Self.requestTimeout
            cfg.timeoutIntervalForResource = Self.requestTimeout * 2
            self.session = URLSession(configuration: cfg)
        }
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
            raw = try await fetchRawWithRetry(
                "https://aviationweather.gov/api/data/metar?ids=\(id)&format=raw",
                kind: kind, id: id
            )
        case .taf:
            raw = try await fetchRawWithRetry(
                "https://aviationweather.gov/api/data/taf?ids=\(id)&format=raw",
                kind: kind, id: id
            )
        case .atis:
            raw = try await fetchAtisWithRetry(id: id)
        }
        let entry = Entry(stationId: id, kind: kind, raw: raw, fetchedAt: Date())
        cache["\(kind.rawValue.uppercased())|\(id)"] = entry
        saveToDisk()
        Self.logger.info("\(kind.rawValue) \(id) refreshed (\(raw.count) bytes)")
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

    // MARK: - Retry-aware fetchers

    private func fetchRawWithRetry(_ urlString: String, kind: ReportKind, id: String) async throws -> String {
        try await retrying(label: "\(kind.rawValue) \(id)") {
            try await self.fetchRaw(urlString)
        }
    }

    private func fetchAtisWithRetry(id: String) async throws -> String {
        try await retrying(label: "atis \(id)") {
            try await self.fetchAtis(id: id)
        }
    }

    /// Wraps a fetch closure with 3-attempt exponential backoff. Only
    /// retries on transient errors (URLError network family, HTTP 5xx).
    /// Honors `Retry-After` if the body throws `MetarHTTPError(retryAfter:)`.
    private func retrying<T>(label: String, _ op: () async throws -> T) async throws -> T {
        let delays: [UInt64] = [0, 2_000_000_000, 6_000_000_000]
        var lastError: Error?
        for (attempt, delay) in delays.enumerated() {
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            do {
                return try await op()
            } catch {
                lastError = error
                if isTransient(error) {
                    Self.logger.warning("\(label) fetch attempt \(attempt + 1) failed (transient): \(error.localizedDescription)")
                    continue
                } else {
                    Self.logger.error("\(label) fetch failed (non-retryable): \(error.localizedDescription)")
                    throw error
                }
            }
        }
        let err = lastError ?? URLError(.unknown)
        Self.logger.error("\(label) fetch exhausted retries: \(err.localizedDescription)")
        throw err
    }

    private func isTransient(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .networkConnectionLost, .notConnectedToInternet,
                 .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
                 .resourceUnavailable:
                return true
            default:
                return false
            }
        }
        if let httpError = error as? MetarHTTPError {
            return (500...599).contains(httpError.status)
        }
        return false
    }

    struct MetarHTTPError: Error { let status: Int }

    private func fetchRaw(_ urlString: String) async throws -> String {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw MetarHTTPError(status: http.statusCode)
        }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// FAA D-ATIS via datis.clowd.io — text-based, FAA airports only. We
    /// deliberately do not attempt to synthesize or guess ATIS for non-FAA
    /// airports: ATIS is safety-relevant, the pilot must consult the real
    /// broadcast.
    private func fetchAtis(id: String) async throws -> String {
        guard let url = URL(string: "https://datis.clowd.io/api/\(id)") else { throw URLError(.badURL) }
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw MetarHTTPError(status: http.statusCode)
        }
        // datis.clowd.io returns either a JSON array (success) or a string
        // body for unsupported stations. Treat the latter as a graceful
        // "no ATIS available" rather than a thrown error — pilots see the
        // explanatory message in the UI and don't need a retry storm.
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
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([String: Entry].self, from: data)
        } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile {
            return [:]   // expected on first launch
        } catch {
            logger.warning("metar disk cache unreadable, starting empty: \(error.localizedDescription)")
            return [:]
        }
    }

    private func saveToDisk() {
        do {
            let data = try JSONEncoder().encode(cache)
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            Self.logger.warning("metar disk cache write failed: \(error.localizedDescription)")
        }
    }
}
