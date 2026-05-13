import Foundation

/// CoinGecko `/simple/price` wrapper with disk cache.
public actor CryptoService {

    public struct Snapshot: Codable, Sendable {
        public let pricesUSD: [String: Double]   // symbol → USD price
        public let timestamp: Date
    }

    private let cacheURL: URL
    private let session: URLSession
    private var inMemory: Snapshot?

    /// CoinGecko IDs for our supported set. Extend as needed.
    public static let supportedCoinGeckoIds: [String: String] = [
        "BTC": "bitcoin", "ETH": "ethereum", "SOL": "solana", "ADA": "cardano",
        "DOGE": "dogecoin", "XRP": "ripple", "DOT": "polkadot", "LTC": "litecoin",
        "AVAX": "avalanche-2", "BNB": "binancecoin", "USDT": "tether", "USDC": "usd-coin",
    ]

    public init(cacheURL: URL? = nil, session: URLSession = .shared) {
        let fm = FileManager.default
        let dir = (try? fm.url(for: .cachesDirectory, in: .userDomainMask,
                               appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.cacheURL = cacheURL ?? dir.appendingPathComponent("crypto.cache.json")
        self.session = session
    }

    public func snapshot() async -> Snapshot? {
        if let s = inMemory {
            // Apply the same 5-min staleness check to in-memory snapshots so
            // the app keeps refreshing rates after the first successful fetch.
            if Date().timeIntervalSince(s.timestamp) > 300 {
                Task { _ = try? await self.refresh() }
            }
            return s
        }
        if let disk = loadFromDisk() {
            inMemory = disk
            if Date().timeIntervalSince(disk.timestamp) > 300 {
                Task { _ = try? await self.refresh() }
            }
            return disk
        }
        return try? await refresh()
    }

    @discardableResult
    public func refresh() async throws -> Snapshot {
        let ids = Self.supportedCoinGeckoIds.values.joined(separator: ",")
        let url = URL(string: "https://api.coingecko.com/api/v3/simple/price?ids=\(ids)&vs_currencies=usd")!
        let (data, _) = try await session.data(from: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: [String: Double]] else {
            throw URLError(.cannotDecodeContentData)
        }
        var prices: [String: Double] = [:]
        for (symbol, geckoId) in Self.supportedCoinGeckoIds {
            if let price = json[geckoId]?["usd"] { prices[symbol] = price }
        }
        let snap = Snapshot(pricesUSD: prices, timestamp: Date())
        inMemory = snap
        saveToDisk(snap)
        return snap
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
