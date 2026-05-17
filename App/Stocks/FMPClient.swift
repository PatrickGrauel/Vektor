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
        case quote                = "quote"
        case historicalPrice1M    = "historical-price-eod/light"

        /// How long a cached response is considered fresh. Financial
        /// statements re-issue quarterly at most, so a week is plenty. Key
        /// metrics include market-cap-derived ratios that move daily, but
        /// they're not used in the DCA scoring path — 24 h is fine. The
        /// quote endpoint must be cheap to re-call (current price); the
        /// 30-day historical close window resets daily after market close.
        var ttl: TimeInterval {
            switch self {
            case .incomeStatement, .balanceSheet, .cashFlow:
                return 7 * 24 * 60 * 60   // 7 days
            case .keyMetrics:
                return 24 * 60 * 60       // 24 hours
            case .profile:
                return 7 * 24 * 60 * 60   // 7 days
            case .quote:
                return 5 * 60             // 5 minutes
            case .historicalPrice1M:
                return 24 * 60 * 60       // 24 hours
            }
        }

        /// Whether the endpoint should be requested with `limit=5`.
        /// Statement endpoints support a row count; profile/quote/historical
        /// have their own shape (or take a date range instead).
        var supportsLimit: Bool {
            switch self {
            case .profile, .quote, .historicalPrice1M: return false
            default:                                    return true
            }
        }

        /// Extra query items beyond the standard `symbol` + `apikey`.
        /// The 1-month historical endpoint needs a `from` date so FMP
        /// returns only the relevant slice (full history would burn
        /// daily-bytes budget for no reason).
        func extraQueryItems(now: Date) -> [URLQueryItem] {
            switch self {
            case .historicalPrice1M:
                // Ask for ~32 days back so we always have at least 21
                // trading days of coverage even after weekends/holidays.
                let cal = Calendar(identifier: .gregorian)
                let from = cal.date(byAdding: .day, value: -32, to: now) ?? now
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd"
                f.timeZone = TimeZone(identifier: "UTC")
                return [URLQueryItem(name: "from", value: f.string(from: from))]
            default:
                return []
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
        case invalidAPIKey
        case symbolNotFound(String)
        /// FMP's "Special Endpoint" 402 — the ticker isn't in the user's
        /// data plan (free tier covers a curated allowlist of US large-
        /// caps; international + delisted + some US large-caps are paid).
        case symbolNotCovered(String)
        case rateLimitExhausted
        case http(Int, String?)
        case network(String)
        case decoding(String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "No Financial Modeling Prep API key set."
            case .invalidAPIKey:
                return "Your Financial Modeling Prep key was rejected. Double-check it in Settings → Stocks."
            case .symbolNotFound(let s):
                return "No data found for \(s)."
            case .symbolNotCovered(let s):
                return "\(s) isn't covered by your FMP plan."
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
        do {
            let payload = try await fetchInner(endpoint, symbol: symbol)
            // Only update the monitor when we actually exercised the
            // network; a pure-cache hit doesn't tell us anything new
            // about the key's health or coverage status.
            if !payload.fromCache {
                let now = Date()
                let upper = symbol.uppercased()
                Task { @MainActor in
                    StocksConnectionMonitor.shared.update(.ok(symbol: upper, at: now))
                }
            }
            return payload
        } catch let error as FMPError {
            let upper = symbol.uppercased()
            switch error {
            case .invalidAPIKey:
                Task { @MainActor in
                    StocksConnectionMonitor.shared.update(.invalidKey)
                }
            case .symbolNotCovered:
                Task { @MainActor in
                    StocksConnectionMonitor.shared.update(.coverageGap(symbol: upper))
                }
            case .rateLimitExhausted:
                Task { @MainActor in
                    StocksConnectionMonitor.shared.update(.rateLimited)
                }
            case .network:
                Task { @MainActor in
                    StocksConnectionMonitor.shared.update(.networkProblem)
                }
            default:
                break
            }
            throw error
        }
    }

    private func fetchInner(_ endpoint: Endpoint, symbol: String) async throws -> Payload {
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

        // Lazy Keychain read: if the cached `apiKey` is still nil from
        // init time but the presence flag says one exists, fetch it now.
        // This is the first Keychain access of the session for users
        // who actually want stocks data — prompt (if any) lands here.
        if (apiKey?.isEmpty ?? true), KeychainStorage.hasKey("tally.stocks.fmpApiKey") {
            self.apiKey = KeychainStorage.get("tally.stocks.fmpApiKey")
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
            let bodyString = String(data: data, encoding: .utf8) ?? ""
            // Classify FMP's 4xx flavours before falling back to cache:
            //   401/403 → key is missing or wrong → don't silently mask
            //             with stale data, surface the auth problem.
            //   402 "Special Endpoint" → the ticker isn't in this plan's
            //             coverage allowlist. Surface as .symbolNotCovered
            //             so the UI can render the calm "not in your plan"
            //             card instead of a red HTTP error.
            //   Everything else → fall through to stale cache if we have it.
            switch http.statusCode {
            case 401, 403:
                throw FMPError.invalidAPIKey
            case 429:
                // FMP's own rate-limit response. We surface this even if
                // Vektor's local cap hasn't fired yet — defence in depth.
                // The cap is a politeness budget; the 429 is the truth.
                throw FMPError.rateLimitExhausted
            case 402:
                if bodyString.contains("Special Endpoint") ||
                   bodyString.localizedCaseInsensitiveContains("not available under your current subscription") {
                    throw FMPError.symbolNotCovered(upper)
                }
                if let cached = cache[symbolEndpointKey(symbol: upper, endpoint: endpoint)] {
                    return Payload(json: cached.json, fetchedAt: cached.fetchedAt,
                                   fromCache: true, stale: true)
                }
                throw FMPError.http(402, bodyString.prefix(200).description)
            default:
                if let cached = cache[symbolEndpointKey(symbol: upper, endpoint: endpoint)] {
                    return Payload(json: cached.json, fetchedAt: cached.fetchedAt,
                                   fromCache: true, stale: true)
                }
                throw FMPError.http(http.statusCode, bodyString.prefix(200).description)
            }
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

    /// Fetch all endpoints required for a DCA analysis + hero badges in
    /// parallel. Returns the bundle plus the budget snapshot for the
    /// footer line.
    ///
    /// The hero-badge endpoints (`quote`, `historicalPrice1M`, sector P/E)
    /// are best-effort: if they fail or aren't on the user's plan, the
    /// hero just hides the corresponding chip rather than killing the
    /// whole analysis.
    struct AnalysisBundle {
        let symbol: String
        let income: Payload
        let balance: Payload
        let cashFlow: Payload
        let keyMetrics: Payload
        let profile: Payload
        /// Hero-badge payloads — optional because a failure on these is
        /// non-fatal. The hero card just hides the chip.
        let quote: Payload?
        let historical1M: Payload?
        let sectorPE: Payload?

        /// Most pessimistic of the five — if any one slot is stale, the
        /// whole scorecard should be labelled stale. Hero-only payloads
        /// don't count: their staleness gets surfaced via their own chip.
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
        // Pre-flight probe: fetch `/income-statement` first as the
        // coverage gate. `/profile` is too lenient — FMP serves profile
        // metadata for international tickers like LHA.DE even on free,
        // but 402s the fundamentals. Gating on income-statement gives a
        // true read of whether the rest of the analysis will succeed.
        //
        // On the success path the income response is cached, so the
        // subsequent `async let income` is a cache hit — same total call
        // count as the parallel-without-probe version.
        // On the failure path we throw .symbolNotCovered after 1 call
        // instead of burning 4+.
        let income = try await fetch(.incomeStatement, symbol: upper)
        async let balance       = fetch(.balanceSheet,     symbol: upper)
        async let cash          = fetch(.cashFlow,         symbol: upper)
        async let metrics       = fetch(.keyMetrics,       symbol: upper)
        async let profile       = fetch(.profile,          symbol: upper)
        async let quote         = try? fetch(.quote,             symbol: upper)
        async let historical1M  = try? fetch(.historicalPrice1M, symbol: upper)

        // Profile is the source of the stock's sector + exchange, which
        // we need to look up the sector P/E. Await it then fan out.
        let profilePayload = try await profile
        let parsedProfile = try? ProfileMini.decode(from: profilePayload.json)
        let sectorPEPayload: Payload?
        if let exch = parsedProfile?.exchangeShortName, !exch.isEmpty {
            sectorPEPayload = try? await fetchSectorPE(exchange: exch)
        } else {
            sectorPEPayload = nil
        }

        return AnalysisBundle(
            symbol: upper,
            income:     income,
            balance:    try await balance,
            cashFlow:   try await cash,
            keyMetrics: try await metrics,
            profile:    profilePayload,
            quote:      await quote,
            historical1M: await historical1M,
            sectorPE:   sectorPEPayload
        )
    }

    /// Minimal profile decoder used for the sector-PE follow-up call —
    /// avoids re-implementing the full profile parser in FMPClient.
    private struct ProfileMini: Decodable {
        let sector: String?
        let exchangeShortName: String?
        static func decode(from data: Data) throws -> ProfileMini? {
            let rows = try JSONDecoder().decode([ProfileMini].self, from: data)
            return rows.first
        }
    }

    /// Sector P/E snapshot for a given exchange. FMP returns one row per
    /// sector on that exchange, so one call covers every stock on that
    /// exchange. Cached 7 days per exchange — sector multiples are slow-
    /// moving and don't need fresher data than that.
    func fetchSectorPE(exchange: String) async throws -> Payload {
        let cacheKey = "__SECTOR__|\(exchange.uppercased())|sector-pe-snapshot"
        let ttl: TimeInterval = 7 * 24 * 60 * 60
        let now = Date()

        rollIfNewDay(now: now)

        if let cached = cache[cacheKey], now.timeIntervalSince(cached.fetchedAt) < ttl {
            return Payload(json: cached.json, fetchedAt: cached.fetchedAt,
                           fromCache: true, stale: false)
        }
        if isBudgetExhausted {
            if let cached = cache[cacheKey] {
                return Payload(json: cached.json, fetchedAt: cached.fetchedAt,
                               fromCache: true, stale: true)
            }
            throw FMPError.rateLimitExhausted
        }
        // Lazy Keychain read: same pattern as the main fetch path —
        // only touch the Keychain when we actually need the value.
        if (apiKey?.isEmpty ?? true), KeychainStorage.hasKey("tally.stocks.fmpApiKey") {
            self.apiKey = KeychainStorage.get("tally.stocks.fmpApiKey")
        }
        guard let key = apiKey, !key.isEmpty else {
            throw FMPError.missingAPIKey
        }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = TimeZone(identifier: "UTC")
        // Use yesterday's date to dodge weekend/holiday gaps in the
        // upstream snapshot.
        let cal = Calendar(identifier: .gregorian)
        let yesterday = cal.date(byAdding: .day, value: -1, to: now) ?? now
        var comps = URLComponents(string: "\(Self.host)/sector-pe-snapshot")!
        comps.queryItems = [
            URLQueryItem(name: "exchange", value: exchange),
            URLQueryItem(name: "date", value: df.string(from: yesterday)),
            URLQueryItem(name: "apikey", value: key),
        ]
        guard let url = comps.url else {
            throw FMPError.network("Could not build sector-PE URL.")
        }

        do {
            budget.callsToday += 1
            persistBudget()
            let (data, response) = try await session.data(from: url)
            budget.bytesToday += data.count
            persistBudget()
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                if let cached = cache[cacheKey] {
                    return Payload(json: cached.json, fetchedAt: cached.fetchedAt,
                                   fromCache: true, stale: true)
                }
                switch http.statusCode {
                case 401, 403: throw FMPError.invalidAPIKey
                case 429:      throw FMPError.rateLimitExhausted
                default:
                    let body = String(data: data, encoding: .utf8) ?? ""
                    throw FMPError.http(http.statusCode, body.prefix(200).description)
                }
            }
            if data == Data("[]".utf8) || data.isEmpty {
                if let cached = cache[cacheKey] {
                    return Payload(json: cached.json, fetchedAt: cached.fetchedAt,
                                   fromCache: true, stale: true)
                }
                throw FMPError.symbolNotFound("sector-pe \(exchange)")
            }
            cache[cacheKey] = CacheEntry(json: data, fetchedAt: now)
            persistCache()
            return Payload(json: data, fetchedAt: now, fromCache: false, stale: false)
        } catch let error as FMPError {
            throw error
        } catch {
            if let cached = cache[cacheKey] {
                return Payload(json: cached.json, fetchedAt: cached.fetchedAt,
                               fromCache: true, stale: true)
            }
            throw FMPError.network(error.localizedDescription)
        }
    }

    /// Fuzzy company-name search. Used by the StocksPane typeahead so
    /// the user can type "Tesla" without knowing TSLA. Returns up to 8
    /// matches, cached 1 hour per query.
    struct SearchHit: Identifiable, Equatable {
        let symbol: String
        let name: String
        let exchange: String?
        let currency: String?
        var id: String { symbol }
    }

    func searchSymbols(query: String, limit: Int = 8) async throws -> [SearchHit] {
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanQuery.count >= 2 else { return [] }
        let cacheKey = "__SEARCH__|\(cleanQuery.lowercased())"
        let ttl: TimeInterval = 60 * 60
        let now = Date()

        rollIfNewDay(now: now)
        if let cached = cache[cacheKey], now.timeIntervalSince(cached.fetchedAt) < ttl {
            return decodeSearch(cached.json).prefix(limit).map { $0 }
        }
        if isBudgetExhausted {
            if let cached = cache[cacheKey] {
                return decodeSearch(cached.json).prefix(limit).map { $0 }
            }
            return []
        }
        if (apiKey?.isEmpty ?? true), KeychainStorage.hasKey("tally.stocks.fmpApiKey") {
            self.apiKey = KeychainStorage.get("tally.stocks.fmpApiKey")
        }
        guard let key = apiKey, !key.isEmpty else { return [] }

        var comps = URLComponents(string: "\(Self.host)/search-name")!
        comps.queryItems = [
            URLQueryItem(name: "query", value: cleanQuery),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "apikey", value: key),
        ]
        guard let url = comps.url else { return [] }

        do {
            budget.callsToday += 1
            persistBudget()
            let (data, response) = try await session.data(from: url)
            budget.bytesToday += data.count
            persistBudget()
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                return []
            }
            cache[cacheKey] = CacheEntry(json: data, fetchedAt: now)
            persistCache()
            return decodeSearch(data).prefix(limit).map { $0 }
        } catch {
            return []
        }
    }

    private func decodeSearch(_ data: Data) -> [SearchHit] {
        struct Row: Decodable {
            let symbol: String?
            let name: String?
            let exchangeShortName: String?
            let exchange: String?
            let currency: String?
        }
        let rows = (try? JSONDecoder().decode([Row].self, from: data)) ?? []
        return rows.compactMap { r in
            guard let sym = r.symbol, let name = r.name else { return nil }
            return SearchHit(symbol: sym, name: name,
                             exchange: r.exchangeShortName ?? r.exchange,
                             currency: r.currency)
        }
    }

    func budgetSnapshot() -> BudgetSnapshot {
        rollIfNewDay(now: Date())
        return BudgetSnapshot(
            callsToday: budget.callsToday,
            callsLimit: dailyCallsLimit,
            bytesToday: budget.bytesToday,
            bytesLimit: Self.dailyBytesLimit,
            resetAt: budget.resetAt
        )
    }

    func setAPIKey(_ key: String?) {
        self.apiKey = key?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Internals

    /// Daily-bytes cap. The call cap is plan-dependent and resolved
    /// from UserDefaults via `FMPPlan.currentDailyCap()` so it tracks
    /// the user's subscription tier instead of pinning everyone at the
    /// free-tier limit.
    private static let dailyBytesLimit = 450 * 1024 * 1024   // 450 MB

    private var dailyCallsLimit: Int { FMPPlan.currentDailyCap() }
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
        // Defer the Keychain read until an actual API call needs it.
        // Reading at init() time would trigger a system Keychain
        // prompt on every ad-hoc rebuild whether the user touches
        // Stocks or not. The presence-flag mirror in UserDefaults
        // gates whether we even attempt the read.
        self.apiKey = nil
    }

    /// Force a fresh Keychain lookup. Called from UI when the user
    /// has just pasted a new key. The Keychain prompt (if signature
    /// changed since the value was stored) fires HERE, in the context
    /// of the user actively saving a key.
    func refreshAPIKeyFromKeychain() {
        guard KeychainStorage.hasKey("tally.stocks.fmpApiKey") else {
            self.apiKey = nil
            return
        }
        self.apiKey = KeychainStorage.get("tally.stocks.fmpApiKey")
    }

    private func makeURL(endpoint: Endpoint, symbol: String, apiKey: String, now: Date = Date()) -> URL {
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
        items.append(contentsOf: endpoint.extraQueryItems(now: now))
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
        budget.callsToday >= dailyCallsLimit ||
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
