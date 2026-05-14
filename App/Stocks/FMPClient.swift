import Foundation
import os

/// Thin client over financialmodelingprep.com's `/stable/` endpoints.
///
/// Owns three things at once because they're entangled on the free tier:
///   1. On-disk JSON cache keyed by (symbol, endpoint), with per-endpoint TTL.
///   2. A daily call counter persisted in UserDefaults — refuses fresh network
///      calls once we cross 240/250 to leave headroom for retries / debugging.
///   3. A daily bytes counter — refuses once we cross 450 MB / 500 MB.
///
/// Cache hits always work, even when the budget is exhausted. Callers get
/// `(payload, age, fromCache)` so the UI can label stale data.
actor FMPClient {

    // MARK: - Public types

    enum Endpoint: String, CaseIterable {
        case incomeStatement      = "income-statement"
        case balanceSheet         = "balance-sheet-statement"
        case cashFlow             = "cash-flow-statement"
        case keyMetrics           = "key-metrics"
        case profile              = "profile"

        /// How long a cached response is considered fresh. Financial
        /// statements re-issue quarterly at most, so a week is plenty. Key
        /// metrics include market-cap-derived ratios that move daily, but
        /// they're not used in the DCA scoring path — 24 h is fine.
        var ttl: TimeInterval {
            switch self {
            case .incomeStatement, .balanceSheet, .cashFlow:
                return 7 * 24 * 60 * 60   // 7 days
            case .keyMetrics:
                return 24 * 60 * 60       // 24 hours
            case .profile:
                return 7 * 24 * 60 * 60   // 7 days
            }
        }

        /// Whether the endpoint should be requested with `limit=10`.
        /// The profile endpoint doesn't take a limit; the statements do.
        var supportsLimit: Bool {
            switch self {
            case .profile: return false
            default:       return true
            }
        }
    }

    /// One returned payload, plus enough metadata to label it in the UI.
    struct Payload {
        let json: Data
        /// When the bytes were originally fetched from the network.
        let fetchedAt: Date
        /// True if we served the cached copy without making a fresh request.
        let fromCache: Bool
        /// True if we served the cached copy even though it was past its TTL,
        /// because the API budget was exhausted or the request failed.
        let stale: Bool

        var ageInDays: Int {
            Int(Date().timeIntervalSince(fetchedAt) / 86400)
        }
    }

    /// Snapshot of the daily budget — surfaced to the pane footer so the
    /// user understands why a new analysis might be refused.
    struct BudgetSnapshot: Equatable {
        let callsToday: Int
        let callsLimit: Int
        let bytesToday: Int
        let bytesLimit: Int
        let resetAt: Date

        var callsRemaining: Int { max(0, callsLimit - callsToday) }
        var isExhausted: Bool { callsToday >= callsLimit || bytesToday >= bytesLimit }
    }

    enum FMPError: LocalizedError {
        case missingAPIKey
        case symbolNotFound(String)
        case rateLimitExhausted
        case http(Int, String?)
        case network(String)
        case decoding(String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "Add your Financial Modeling Prep API key in Settings → Advanced."
            case .symbolNotFound(let s):
                return "No data found for \(s)."
            case .rateLimitExhausted:
                return "API budget exhausted for today. Previously-analysed tickers still work from cache."
            case .http(let code, let body):
                let detail = body.map { " — \($0)" } ?? ""
                return "FMP returned HTTP \(code)\(detail)."
            case .network(let m):
                return "Network error: \(m)"
            case .decoding(let m):
                return "Could not parse FMP response: \(m)"
            }
        }
    }

    // MARK: - Public surface

    static let shared = FMPClient()

    /// Fetch a single endpoint for a symbol. The returned payload comes
    /// from cache when fresh, from the network otherwise, and from cache
    /// (stale-tagged) when the network can't be used.
    func fetch(_ endpoint: Endpoint, symbol: String) async throws -> Payload {
        let upper = symbol.uppercased()
        let key = cacheKey(symbol: upper, endpoint: endpoint)
        let now = Date()

        rollIfNewDay(now: now)

        // 1. Fresh cache hit — return it without touching the network.
        if let cached = cache[key], now.timeIntervalSince(cached.fetchedAt) < endpoint.ttl {
            return Payload(json: cached.json, fetchedAt: cached.fetchedAt,
                           fromCache: true, stale: false)
        }

        // 2. Need the network. If we're out of budget but have *any* cached
        //    copy, hand it back tagged stale rather than refusing outright.
        if isBudgetExhausted {
            if let cached = cache[key] {
                return Payload(json: cached.json, fetchedAt: cached.fetchedAt,
                               fromCache: true, stale: true)
            }
            throw FMPError.rateLimitExhausted
        }

        guard let key = apiKey, !key.isEmpty else {
            throw FMPError.missingAPIKey
        }

        // 3. Network fetch — count the call and the bytes against today's
        //    budget regardless of outcome (FMP charges for failed calls
        //    too on the free tier in practice).
        let url = makeURL(endpoint: endpoint, symbol: upper, apiKey: key)
        let result: (Data, URLResponse)
        do {
            budget.callsToday += 1
            persistBudget()
            result = try await session.data(from: url)
        } catch {
            // Fall back to stale cache if we can.
            if let cached = cache[symbolEndpointKey(symbol: upper, endpoint: endpoint)] {
                return Payload(json: cached.json, fetchedAt: cached.fetchedAt,
                               fromCache: true, stale: true)
            }
            throw FMPError.network(error.localizedDescription)
        }
        let (data, response) = result
        budget.bytesToday += data.count
        persistBudget()

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let body = String(data: data, encoding: .utf8)?.prefix(200).description
            // 401/403 → key issue; anything 4xx/5xx fall through to cache.
            if let cached = cache[symbolEndpointKey(symbol: upper, endpoint: endpoint)] {
                return Payload(json: cached.json, fetchedAt: cached.fetchedAt,
                               fromCache: true, stale: true)
            }
            throw FMPError.http(http.statusCode, body)
        }

        // FMP returns a `{"Error Message": "..."}` body on lookup misses or
        // on legacy-key issues — detect both before stashing the result.
        if let str = String(data: data, encoding: .utf8),
           str.contains("Error Message") {
            // No useful cache fallback for a true 404 — surface the error.
            if str.localizedCaseInsensitiveContains("not found") ||
               str.localizedCaseInsensitiveContains("no data") {
                throw FMPError.symbolNotFound(upper)
            }
            throw FMPError.http(200, str)
        }

        // FMP returns `[]` for an unknown symbol on most endpoints.
        if data == Data("[]".utf8) || data.isEmpty {
            throw FMPError.symbolNotFound(upper)
        }

        let cacheKey = symbolEndpointKey(symbol: upper, endpoint: endpoint)
        cache[cacheKey] = CacheEntry(json: data, fetchedAt: now)
        persistCache()

        return Payload(json: data, fetchedAt: now, fromCache: false, stale: false)
    }

    /// Fetch all 5 endpoints required for a DCA analysis in parallel.
    /// Returns the bundle plus the budget snapshot for the footer line.
    struct AnalysisBundle {
        let symbol: String
        let income: Payload
        let balance: Payload
        let cashFlow: Payload
        let keyMetrics: Payload
        let profile: Payload

        /// Most pessimistic of the five — if any one slot is stale, the
        /// whole scorecard should be labelled stale.
        var stale: Bool {
            income.stale || balance.stale || cashFlow.stale ||
            keyMetrics.stale || profile.stale
        }

        /// True if every slot came from cache. Surfaced as "fully cached".
        var fullyCached: Bool {
            income.fromCache && balance.fromCache && cashFlow.fromCache &&
            keyMetrics.fromCache && profile.fromCache
        }

        var oldestFetch: Date {
            [income, balance, cashFlow, keyMetrics, profile]
                .map(\.fetchedAt).min() ?? Date()
        }
    }

    func analyse(symbol: String) async throws -> AnalysisBundle {
        let upper = symbol.uppercased()
        async let income   = fetch(.incomeStatement, symbol: upper)
        async let balance  = fetch(.balanceSheet,    symbol: upper)
        async let cash     = fetch(.cashFlow,        symbol: upper)
        async let metrics  = fetch(.keyMetrics,      symbol: upper)
        async let profile  = fetch(.profile,         symbol: upper)
        return AnalysisBundle(
            symbol: upper,
            income:     try await income,
            balance:    try await balance,
            cashFlow:   try await cash,
            keyMetrics: try await metrics,
            profile:    try await profile
        )
    }

    func budgetSnapshot() -> BudgetSnapshot {
        rollIfNewDay(now: Date())
        return BudgetSnapshot(
            callsToday: budget.callsToday,
            callsLimit: Self.dailyCallsLimit,
            bytesToday: budget.bytesToday,
            bytesLimit: Self.dailyBytesLimit,
            resetAt: budget.resetAt
        )
    }

    func setAPIKey(_ key: String?) {
        self.apiKey = key?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Internals

    /// Soft daily cap. FMP free tier is 250 calls/day — we stop at 240 so
    /// retries and a refresh button click after an error don't push us over.
    private static let dailyCallsLimit = 240
    private static let dailyBytesLimit = 450 * 1024 * 1024   // 450 MB
    private static let logger = Logger(subsystem: "app.tally.Tally", category: "fmp")
    private static let host = "https://financialmodelingprep.com/stable"

    private struct CacheEntry: Codable {
        let json: Data
        let fetchedAt: Date
    }

    private struct DailyBudget: Codable {
        var callsToday: Int
        var bytesToday: Int
        var resetAt: Date
    }

    private let session: URLSession
    private let cacheURL: URL
    private var cache: [String: CacheEntry] = [:]
    private var budget: DailyBudget
    private var apiKey: String?

    init(cacheURL: URL? = nil, session: URLSession? = nil) {
        let fm = FileManager.default
        let dir = (try? fm.url(for: .cachesDirectory, in: .userDomainMask,
                               appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.cacheURL = cacheURL ?? dir.appendingPathComponent("fmp.cache.json")
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 20
            cfg.timeoutIntervalForResource = 40
            self.session = URLSession(configuration: cfg)
        }
        self.budget = Self.loadBudget()
        self.cache = Self.loadCache(at: self.cacheURL)
        self.apiKey = UserDefaults.standard.string(forKey: "tally.stocks.fmpApiKey")
    }

    private func makeURL(endpoint: Endpoint, symbol: String, apiKey: String) -> URL {
        var comps = URLComponents(string: "\(Self.host)/\(endpoint.rawValue)")!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "symbol", value: symbol),
            URLQueryItem(name: "apikey", value: apiKey),
        ]
        if endpoint.supportsLimit {
            // FMP free tier caps `limit` at 5 (returns HTTP 402 above that).
            // The DCA framework wants 10 years; we accept what the free
            // tier gives us and flag the shorter window in the rationale.
            items.append(URLQueryItem(name: "limit", value: "5"))
        }
        comps.queryItems = items
        return comps.url!
    }

    private func cacheKey(symbol: String, endpoint: Endpoint) -> String {
        symbolEndpointKey(symbol: symbol, endpoint: endpoint)
    }
    private func symbolEndpointKey(symbol: String, endpoint: Endpoint) -> String {
        "\(symbol)|\(endpoint.rawValue)"
    }

    private var isBudgetExhausted: Bool {
        budget.callsToday >= Self.dailyCallsLimit ||
        budget.bytesToday >= Self.dailyBytesLimit
    }

    private func rollIfNewDay(now: Date) {
        // FMP resets at midnight UTC per their docs. We store `resetAt` as
        // the *current* day's start-of-day (UTC) — if `now` is in a later
        // UTC day, roll the counter. Storing the start-of-day rather than
        // the next-reset moment lets `isDate(_:inSameDayAs:)` answer
        // "is the recorded reset still today?" with a single, obvious comparison.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let today = utc.startOfDay(for: now)
        if budget.resetAt < today {
            budget = DailyBudget(callsToday: 0, bytesToday: 0, resetAt: today)
            persistBudget()
        }
    }

    private func persistBudget() {
        UserDefaults.standard.set(budget.callsToday, forKey: "tally.stocks.callsToday")
        UserDefaults.standard.set(budget.bytesToday, forKey: "tally.stocks.bytesToday")
        UserDefaults.standard.set(budget.resetAt,    forKey: "tally.stocks.callsResetAt")
    }

    private static func loadBudget() -> DailyBudget {
        let ud = UserDefaults.standard
        let calls = ud.integer(forKey: "tally.stocks.callsToday")
        let bytes = ud.integer(forKey: "tally.stocks.bytesToday")
        let reset = (ud.object(forKey: "tally.stocks.callsResetAt") as? Date)
            ?? Date(timeIntervalSince1970: 0)
        return DailyBudget(callsToday: calls, bytesToday: bytes, resetAt: reset)
    }

    private func persistCache() {
        do {
            let data = try JSONEncoder().encode(cache)
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            Self.logger.error("fmp: failed to persist cache: \(error.localizedDescription)")
        }
    }

    private static func loadCache(at url: URL) -> [String: CacheEntry] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: CacheEntry].self, from: data)) ?? [:]
    }
}
