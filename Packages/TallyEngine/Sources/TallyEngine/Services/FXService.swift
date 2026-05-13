import Foundation

/// Live FX rate fetcher with disk cache + stale-while-revalidate semantics.
/// Source: OpenExchangeRates (requires a free API key from openexchangerates.org).
/// When no key is configured the engine simply runs without live FX rates.
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

    private let cacheURL: URL
    private let session: URLSession
    private var inMemory: Snapshot?

    public init(cacheURL: URL? = nil, session: URLSession = .shared) {
        let fm = FileManager.default
        let dir = (try? fm.url(for: .cachesDirectory, in: .userDomainMask,
                               appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.cacheURL = cacheURL ?? dir.appendingPathComponent("fx.cache.json")
        self.session = session
    }

    /// Returns the freshest snapshot we have. If the cached snapshot (in
    /// memory OR on disk) is stale (>1h) we kick off a refresh but still
    /// return cached data immediately (stale-while-revalidate).
    public func snapshot(using source: Source) async -> Snapshot? {
        if let s = inMemory {
            if Date().timeIntervalSince(s.timestamp) > 3600 {
                Task { _ = try? await self.refresh(using: source) }
            }
            return s
        }
        if let disk = loadFromDisk() {
            inMemory = disk
            if Date().timeIntervalSince(disk.timestamp) > 3600 {
                Task { _ = try? await self.refresh(using: source) }
            }
            return disk
        }
        return try? await refresh(using: source)
    }

    @discardableResult
    public func refresh(using source: Source) async throws -> Snapshot {
        let snapshot: Snapshot
        switch source {
        case .openExchangeRates(let appId): snapshot = try await fetchOXR(appId: appId)
        case .frankfurter:                  snapshot = try await fetchFrankfurter()
        }
        inMemory = snapshot
        saveToDisk(snapshot)
        return snapshot
    }

    private func fetchOXR(appId: String) async throws -> Snapshot {
        let url = URL(string: "https://openexchangerates.org/api/latest.json?app_id=\(appId)")!
        let (data, _) = try await session.data(from: url)
        struct OXR: Decodable { let timestamp: TimeInterval; let base: String; let rates: [String: Double] }
        let decoded = try JSONDecoder().decode(OXR.self, from: data)
        return Snapshot(base: "USD",
                        ratesPerUSD: decoded.rates,
                        timestamp: Date(timeIntervalSince1970: decoded.timestamp))
    }

    /// Frankfurter publishes ECB reference rates. Call with `from=USD` so the
    /// response shape matches OXR's "per USD" semantics.
    private func fetchFrankfurter() async throws -> Snapshot {
        let url = URL(string: "https://api.frankfurter.dev/v1/latest?base=USD")!
        let (data, _) = try await session.data(from: url)
        struct FR: Decodable { let amount: Double; let base: String; let date: String; let rates: [String: Double] }
        let decoded = try JSONDecoder().decode(FR.self, from: data)
        var rates = decoded.rates
        // Frankfurter omits the base from `rates`; add USD=1 for symmetry.
        rates["USD"] = 1.0
        // Date is just "yyyy-MM-dd" — parse as noon UTC so timestamps stay sane.
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyy-MM-dd"
        let stamp = (fmt.date(from: decoded.date) ?? Date()).addingTimeInterval(12 * 3600)
        return Snapshot(base: "USD", ratesPerUSD: rates, timestamp: stamp)
    }

    private func loadFromDisk() -> Snapshot? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    private func saveToDisk(_ snapshot: Snapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }
}
