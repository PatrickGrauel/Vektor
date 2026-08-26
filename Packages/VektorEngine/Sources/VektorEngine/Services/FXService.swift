import Foundation
import os

/// Live FX rate fetcher with disk cache + stale-while-revalidate semantics.
///
/// The preferred consumer API is `snapshots(using:)`, which is an
/// `AsyncStream<Snapshot>` that yields:
///   1. The cached snapshot (from disk, if any) immediately, OR the result
///      of the first network fetch if there is no disk cache yet.
///   2. Every subsequent successful background refresh.
///
/// This closes a gap in the older one-shot `snapshot(using:)` API, which
/// returned cached data and then fired a background refresh but never
/// notified the consumer about the refresh result — meaning the engine
/// stayed on whatever rates landed at launch forever, even if the
/// background fetch did update the cache.
///
/// Source: OpenExchangeRates (requires a free API key from
/// openexchangerates.org). When no key is configured the engine falls back
/// to Frankfurter (free ECB-based rates, no key).
public actor FXService {

    public struct Snapshot: Codable, Sendable {
        public let base: String
        /// Per-USD rates: how many UNIT equal 1 USD.
        public let ratesPerUSD: [String: Double]
        /// The as-of date of the rates themselves — ECB publication day
        /// (noon UTC) for Frankfurter, the provider's tick for OXR/er-api.
        /// This is what the UI shows as provenance.
        public let timestamp: Date
        /// When WE last fetched this snapshot. Drives the refresh cadence,
        /// and must stay distinct from `timestamp`: daily sources (ECB)
        /// are always hours old, so keying staleness off `timestamp` makes
        /// every snapshot look permanently stale and the polling loop
        /// re-fetches every 60 s all day.
        public let fetchedAt: Date

        init(base: String, ratesPerUSD: [String: Double], timestamp: Date,
             fetchedAt: Date = Date()) {
            self.base = base
            self.ratesPerUSD = ratesPerUSD
            self.timestamp = timestamp
            self.fetchedAt = fetchedAt
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            base = try c.decode(String.self, forKey: .base)
            ratesPerUSD = try c.decode([String: Double].self, forKey: .ratesPerUSD)
            timestamp = try c.decode(Date.self, forKey: .timestamp)
            // Caches written before `fetchedAt` existed: treat the rate
            // date as the fetch date — worst case is one extra refresh.
            fetchedAt = try c.decodeIfPresent(Date.self, forKey: .fetchedAt) ?? timestamp
        }
    }

    public enum Source: Sendable {
        case openExchangeRates(appId: String)
        /// Frankfurter — free ECB-based rates, no API key. Covers ~30 majors
        /// (EUR, USD, GBP, HUF, CZK, PLN, …).
        case frankfurter
        /// ECB (Frankfurter) for its ~30 authoritative majors, with the gaps
        /// filled from open.er-api.com (free, no key, ~160 currencies incl.
        /// RUB — which the ECB stopped publishing in 2022). ECB wins on any
        /// overlap; er-api only supplies codes ECB omits. The no-key default.
        case ecbWithERApiFallback
    }

    private static let logger = Logger(subsystem: "app.vektor.Vektor", category: "fx")

    /// `URLSession` timeout for FX fetches. Default URLSession waits 60 s
    /// before timing out, which is too long for a calculator UI — caps
    /// the worst-case stall at 15 s + retry backoff.
    private static let requestTimeout: TimeInterval = 15

    /// Background-refresh cadence. Snapshots older than this trigger a
    /// new fetch when `snapshot(using:)` is called or when the active
    /// `snapshots` stream's polling task ticks.
    private static let staleAfter: TimeInterval = 3600 // 1 hour

    private let cacheURL: URL
    private let session: URLSession
    private var inMemory: Snapshot?

    /// Stream continuations for active `snapshots(using:)` consumers. The
    /// stream stays alive for the lifetime of the consumer (typically the
    /// `AppModel`); on every successful refresh we push the new snapshot
    /// into all continuations so they re-apply rates.
    private var continuations: [UUID: AsyncStream<Snapshot>.Continuation] = [:]

    /// Per-source polling task — re-fetches every `staleAfter` interval
    /// while the consumer is connected. One per source (we only have one
    /// active source at a time in practice).
    private var pollingTasks: [String: Task<Void, Never>] = [:]

    public init(cacheURL: URL? = nil, session: URLSession? = nil) {
        let fm = FileManager.default
        let dir = (try? fm.url(for: .cachesDirectory, in: .userDomainMask,
                               appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.cacheURL = cacheURL ?? dir.appendingPathComponent("fx.cache.json")
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = Self.requestTimeout
            cfg.timeoutIntervalForResource = Self.requestTimeout * 2
            // Bypass the HTTP-layer cache entirely. Frankfurter serves
            // `latest` with `cache-control: max-age=86400`, so the default
            // URLCache happily replays YESTERDAY's rates for up to a day
            // while we believe we just fetched fresh ones. We keep our own
            // disk snapshot with explicit staleness — the URL cache only
            // undermines it.
            cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
            cfg.urlCache = nil
            self.session = URLSession(configuration: cfg)
        }
    }

    // MARK: - Legacy one-shot API (kept for tests / migration)
    //
    // Existing callers can keep using this — but the resulting consumer
    // only sees one snapshot per call. For continuous re-application
    // after every background refresh, use `snapshots(using:)`.

    public func snapshot(using source: Source) async -> Snapshot? {
        if let s = inMemory {
            if isStale(s) {
                Task { _ = try? await self.refresh(using: source) }
            }
            return s
        }
        if let disk = loadFromDisk() {
            inMemory = disk
            if isStale(disk) {
                Task { _ = try? await self.refresh(using: source) }
            }
            return disk
        }
        return try? await refreshWithRetry(using: source)
    }

    private func isStale(_ snapshot: Snapshot) -> Bool {
        Date().timeIntervalSince(snapshot.fetchedAt) > Self.staleAfter
    }

    /// Refresh only when the current snapshot is missing or past the
    /// staleness window. The app calls this on scene activation so a Mac
    /// waking from overnight sleep doesn't keep showing yesterday's rates
    /// until the next polling tick. A successful fetch broadcasts to all
    /// active `snapshots(using:)` consumers.
    @discardableResult
    public func refreshIfStale(using source: Source) async throws -> Snapshot? {
        let current: Snapshot?
        if let s = inMemory {
            current = s
        } else if let disk = loadFromDisk() {
            inMemory = disk
            current = disk
        } else {
            current = nil
        }
        if let current, !isStale(current) { return nil }
        return try await refreshWithRetry(using: source)
    }

    // MARK: - Stream API
    //
    // Preferred. Yields the current snapshot (from disk if available, or
    // from a fresh fetch otherwise), then yields again after every
    // successful background refresh until the consumer stops iterating.

    public func snapshots(using source: Source) -> AsyncStream<Snapshot> {
        let key = sourceKey(source)
        return AsyncStream { continuation in
            let id = UUID()
            Task { await self.attach(continuation: continuation, id: id, source: source, key: key) }
            continuation.onTermination = { @Sendable [weak self] _ in
                guard let self else { return }
                Task { await self.detach(id: id, key: key) }
            }
        }
    }

    private func attach(continuation: AsyncStream<Snapshot>.Continuation, id: UUID, source: Source, key: String) async {
        continuations[id] = continuation
        // Push the current snapshot ASAP — cached if we have it, otherwise
        // the result of a synchronous (first-launch) fetch.
        var cached: Snapshot?
        if let s = inMemory {
            cached = s
        } else if let disk = loadFromDisk() {
            inMemory = disk
            cached = disk
        }
        if let cached {
            continuation.yield(cached)
            // Stale cache (e.g. app launched after a night's sleep): don't
            // sit on it until the polling tick ≥60 s out — refresh now.
            // Success broadcasts to every consumer, including this one.
            if isStale(cached) {
                Task { _ = try? await self.refreshWithRetry(using: source) }
            }
        } else {
            // No cache at all: fetch before returning so the first yield is
            // real data. refreshWithRetry broadcasts on success, and this
            // continuation is already registered, so no explicit yield.
            _ = try? await refreshWithRetry(using: source)
        }
        // Ensure a polling task is running for this source.
        startPolling(source: source, key: key)
    }

    private func detach(id: UUID, key: String) {
        continuations[id] = nil
        // If no one's listening on this source anymore, stop polling.
        if continuations.isEmpty {
            pollingTasks[key]?.cancel()
            pollingTasks[key] = nil
        }
    }

    private func startPolling(source: Source, key: String) {
        guard pollingTasks[key] == nil else { return }
        pollingTasks[key] = Task { [weak self] in
            while !Task.isCancelled {
                // Sleep until the current snapshot is past its staleness
                // window. If we have no snapshot yet, poll every 60 s
                // (initial fetch loop on offline launch).
                let interval: TimeInterval = await {
                    guard let self else { return 60 }
                    if let s = await self.inMemorySnapshot() {
                        let age = Date().timeIntervalSince(s.fetchedAt)
                        return max(60, Self.staleAfter - age)
                    }
                    return 60
                }()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { return }
                guard let self else { return }
                // refreshWithRetry broadcasts on success.
                _ = try? await self.refreshWithRetry(using: source)
            }
        }
    }

    private func inMemorySnapshot() -> Snapshot? { inMemory }

    private func broadcast(_ snapshot: Snapshot) {
        for c in continuations.values { c.yield(snapshot) }
    }

    // MARK: - Refresh with retry

    @discardableResult
    public func refresh(using source: Source) async throws -> Snapshot {
        try await refreshWithRetry(using: source)
    }

    /// Retry on transient errors only (URLError transient set, HTTP 5xx).
    /// Backoff: 0 / 2 s / 6 s. Returns the first successful snapshot;
    /// throws the LAST error if all attempts fail.
    private func refreshWithRetry(using source: Source) async throws -> Snapshot {
        let delays: [UInt64] = [0, 2_000_000_000, 6_000_000_000]
        var lastError: Error?
        for (attempt, delay) in delays.enumerated() {
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            do {
                let snapshot = try await fetchOnce(using: source)
                inMemory = snapshot
                saveToDisk(snapshot)
                // Single broadcast point: every successful refresh —
                // polling tick, foreground kick, or explicit refresh() —
                // reaches all stream consumers, so the engine can never
                // stay behind a cache that did update.
                broadcast(snapshot)
                if attempt > 0 {
                    Self.logger.info("FX fetched on retry \(attempt): base=\(snapshot.base), \(snapshot.ratesPerUSD.count) rates, ts=\(snapshot.timestamp)")
                } else {
                    Self.logger.info("FX fetched: base=\(snapshot.base), \(snapshot.ratesPerUSD.count) rates, ts=\(snapshot.timestamp)")
                }
                return snapshot
            } catch {
                lastError = error
                if isTransient(error) {
                    Self.logger.warning("FX fetch attempt \(attempt + 1) failed (transient): \(error.localizedDescription)")
                    continue
                } else {
                    Self.logger.error("FX fetch failed (non-retryable): \(error.localizedDescription)")
                    throw error
                }
            }
        }
        // All retries exhausted.
        let err = lastError ?? URLError(.unknown)
        Self.logger.error("FX fetch exhausted retries: \(err.localizedDescription)")
        throw err
    }

    private func fetchOnce(using source: Source) async throws -> Snapshot {
        switch source {
        case .openExchangeRates(let appId): return try await fetchOXR(appId: appId)
        case .frankfurter:                  return try await fetchFrankfurter()
        case .ecbWithERApiFallback:         return try await fetchECBWithFallback()
        }
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
        if let httpError = error as? HTTPError {
            return (500...599).contains(httpError.status)
        }
        return false
    }

    struct HTTPError: Error { let status: Int }

    // MARK: - Source-specific fetchers

    private func fetchOXR(appId: String) async throws -> Snapshot {
        guard let url = URL(string: "https://openexchangerates.org/api/latest.json?app_id=\(appId)") else {
            throw URLError(.badURL)
        }
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HTTPError(status: http.statusCode)
        }
        struct OXR: Decodable { let timestamp: TimeInterval; let base: String; let rates: [String: Double] }
        let decoded = try JSONDecoder().decode(OXR.self, from: data)
        return Snapshot(base: "USD",
                        ratesPerUSD: decoded.rates,
                        timestamp: Date(timeIntervalSince1970: decoded.timestamp))
    }

    /// Frankfurter publishes ECB reference rates. Call with `base=USD` so the
    /// response shape matches OXR's "per USD" semantics.
    private func fetchFrankfurter() async throws -> Snapshot {
        guard let url = URL(string: "https://api.frankfurter.dev/v1/latest?base=USD") else {
            throw URLError(.badURL)
        }
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HTTPError(status: http.statusCode)
        }
        struct FR: Decodable { let amount: Double; let base: String; let date: String; let rates: [String: Double] }
        let decoded = try JSONDecoder().decode(FR.self, from: data)
        var rates = decoded.rates
        // Frankfurter omits the base from `rates`; add USD=1 for symmetry.
        rates["USD"] = 1.0
        // Date is just "yyyy-MM-dd" — parse as noon UTC so timestamps stay sane.
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        // Defensive: fall back to GMT if the UTC identifier ever returns nil
        // (extremely unlikely, but avoids a force-unwrap in this hot path).
        fmt.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0) ?? .current
        fmt.dateFormat = "yyyy-MM-dd"
        let stamp = (fmt.date(from: decoded.date) ?? Date()).addingTimeInterval(12 * 3600)
        return Snapshot(base: "USD", ratesPerUSD: rates, timestamp: stamp)
    }

    /// open.er-api.com — free, no API key, ~160 currencies, USD-based,
    /// refreshed ~daily. Used to fill currencies the ECB feed omits (RUB,
    /// AED, and the long tail). Signals logical failure in-band with a 200
    /// body whose `result` is not `"success"`, so we check that explicitly.
    private func fetchERApi() async throws -> Snapshot {
        guard let url = URL(string: "https://open.er-api.com/v6/latest/USD") else {
            throw URLError(.badURL)
        }
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HTTPError(status: http.statusCode)
        }
        struct ERApi: Decodable {
            let result: String
            let time_last_update_unix: TimeInterval?
            let rates: [String: Double]
        }
        let decoded = try JSONDecoder().decode(ERApi.self, from: data)
        guard decoded.result == "success" else { throw HTTPError(status: 502) }
        let stamp = decoded.time_last_update_unix.map { Date(timeIntervalSince1970: $0) } ?? Date()
        return Snapshot(base: "USD", ratesPerUSD: decoded.rates, timestamp: stamp)
    }

    /// ECB-primary, er-api-fallback merge. Both feeds run concurrently and
    /// are USD-based, so combining is a plain key union with ECB winning on
    /// overlap. Resilient: if only one feed fails we still return the other;
    /// only when BOTH fail do we surface an error so retry/backoff applies.
    private func fetchECBWithFallback() async throws -> Snapshot {
        async let ecbThrows = fetchFrankfurter()
        async let erThrows  = fetchERApi()
        let ecb = try? await ecbThrows
        let er  = try? await erThrows

        guard ecb != nil || er != nil else {
            // Both failed — re-run the primary so its real (typed) error
            // propagates into refreshWithRetry's transient classification.
            return try await fetchFrankfurter()
        }

        let merged = Self.mergeRates(primary: ecb?.ratesPerUSD ?? [:],
                                     fallback: er?.ratesPerUSD ?? [:])
        // Prefer ECB's timestamp (authoritative cadence) when present.
        let stamp = ecb?.timestamp ?? er?.timestamp ?? Date()
        return Snapshot(base: "USD", ratesPerUSD: merged, timestamp: stamp)
    }

    /// Union of two USD-based rate tables; `primary` wins on any overlapping
    /// code, `fallback` fills the rest. Pure — unit-tested directly.
    static func mergeRates(primary: [String: Double],
                           fallback: [String: Double]) -> [String: Double] {
        var merged = fallback
        for (code, rate) in primary { merged[code] = rate }
        return merged
    }

    // MARK: - Disk cache

    private func loadFromDisk() -> Snapshot? {
        do {
            let data = try Data(contentsOf: cacheURL)
            return try JSONDecoder().decode(Snapshot.self, from: data)
        } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile {
            return nil   // expected on first launch
        } catch {
            Self.logger.warning("FX disk cache unreadable, will refetch: \(error.localizedDescription)")
            return nil
        }
    }

    private func saveToDisk(_ snapshot: Snapshot) {
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            Self.logger.warning("FX disk cache write failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Misc

    private func sourceKey(_ source: Source) -> String {
        switch source {
        case .openExchangeRates:    return "oxr"
        case .frankfurter:          return "frankfurter"
        case .ecbWithERApiFallback: return "ecb+er"
        }
    }
}
