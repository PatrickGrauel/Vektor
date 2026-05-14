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
        public let timestamp: Date
    }

    public enum Source: Sendable {
        case openExchangeRates(appId: String)
        /// Frankfurter — free ECB-based rates, no API key. Covers ~30 majors
        /// (EUR, USD, GBP, HUF, CZK, PLN, …) and is used as the default
        /// fallback when no OXR key is configured.
        case frankfurter
    }

    private static let logger = Logger(subsystem: "app.tally.Tally", category: "fx")

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
            if Date().timeIntervalSince(s.timestamp) > Self.staleAfter {
                Task { _ = try? await self.refresh(using: source) }
            }
            return s
        }
        if let disk = loadFromDisk() {
            inMemory = disk
            if Date().timeIntervalSince(disk.timestamp) > Self.staleAfter {
                Task { _ = try? await self.refresh(using: source) }
            }
            return disk
        }
        return try? await refreshWithRetry(using: source)
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
        if let s = inMemory {
            continuation.yield(s)
        } else if let disk = loadFromDisk() {
            inMemory = disk
            continuation.yield(disk)
        } else if let fresh = try? await refreshWithRetry(using: source) {
            continuation.yield(fresh)
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
                        let age = Date().timeIntervalSince(s.timestamp)
                        return max(60, Self.staleAfter - age)
                    }
                    return 60
                }()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { return }
                guard let self else { return }
                if let fresh = try? await self.refreshWithRetry(using: source) {
                    await self.broadcast(fresh)
                }
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
        case .openExchangeRates: return "oxr"
        case .frankfurter:       return "frankfurter"
        }
    }
}
