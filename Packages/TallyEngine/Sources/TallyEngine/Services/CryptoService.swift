import Foundation
import os

/// CoinGecko `/simple/price` wrapper with disk cache + retry + AsyncStream.
///
/// Mirrors `FXService` semantics — `snapshots()` is the preferred consumer
/// API; the legacy `snapshot()` getter is kept for tests/migration.
public actor CryptoService {

    public struct Snapshot: Codable, Sendable {
        public let pricesUSD: [String: Double]   // symbol → USD price
        public let timestamp: Date
    }

    private static let logger = Logger(subsystem: "app.tally.Tally", category: "crypto")
    private static let staleAfter: TimeInterval = 300   // 5 min
    private static let requestTimeout: TimeInterval = 15

    private let cacheURL: URL
    private let session: URLSession
    private var inMemory: Snapshot?

    private var continuations: [UUID: AsyncStream<Snapshot>.Continuation] = [:]
    private var pollingTask: Task<Void, Never>?

    /// CoinGecko IDs for our supported set. Extend as needed.
    public static let supportedCoinGeckoIds: [String: String] = [
        "BTC": "bitcoin", "ETH": "ethereum", "SOL": "solana", "ADA": "cardano",
        "DOGE": "dogecoin", "XRP": "ripple", "DOT": "polkadot", "LTC": "litecoin",
        "AVAX": "avalanche-2", "BNB": "binancecoin", "USDT": "tether", "USDC": "usd-coin",
    ]

    public init(cacheURL: URL? = nil, session: URLSession? = nil) {
        let fm = FileManager.default
        let dir = (try? fm.url(for: .cachesDirectory, in: .userDomainMask,
                               appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.cacheURL = cacheURL ?? dir.appendingPathComponent("crypto.cache.json")
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = Self.requestTimeout
            cfg.timeoutIntervalForResource = Self.requestTimeout * 2
            self.session = URLSession(configuration: cfg)
        }
    }

    // MARK: - Legacy one-shot API

    public func snapshot() async -> Snapshot? {
        if let s = inMemory {
            if Date().timeIntervalSince(s.timestamp) > Self.staleAfter {
                Task { _ = try? await self.refresh() }
            }
            return s
        }
        if let disk = loadFromDisk() {
            inMemory = disk
            if Date().timeIntervalSince(disk.timestamp) > Self.staleAfter {
                Task { _ = try? await self.refresh() }
            }
            return disk
        }
        return try? await refreshWithRetry()
    }

    // MARK: - Stream API

    public func snapshots() -> AsyncStream<Snapshot> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.attach(continuation: continuation, id: id) }
            continuation.onTermination = { @Sendable [weak self] _ in
                guard let self else { return }
                Task { await self.detach(id: id) }
            }
        }
    }

    private func attach(continuation: AsyncStream<Snapshot>.Continuation, id: UUID) async {
        continuations[id] = continuation
        if let s = inMemory {
            continuation.yield(s)
        } else if let disk = loadFromDisk() {
            inMemory = disk
            continuation.yield(disk)
        } else if let fresh = try? await refreshWithRetry() {
            continuation.yield(fresh)
        }
        startPolling()
    }

    private func detach(id: UUID) {
        continuations[id] = nil
        if continuations.isEmpty {
            pollingTask?.cancel()
            pollingTask = nil
        }
    }

    private func startPolling() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval: TimeInterval = await {
                    guard let self else { return 60 }
                    if let s = await self.inMemorySnapshot() {
                        return max(60, Self.staleAfter - Date().timeIntervalSince(s.timestamp))
                    }
                    return 60
                }()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { return }
                guard let self else { return }
                if let fresh = try? await self.refreshWithRetry() {
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
    public func refresh() async throws -> Snapshot {
        try await refreshWithRetry()
    }

    private func refreshWithRetry() async throws -> Snapshot {
        let delays: [UInt64] = [0, 2_000_000_000, 6_000_000_000]
        var lastError: Error?
        for (attempt, delay) in delays.enumerated() {
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            do {
                let snapshot = try await fetchOnce()
                inMemory = snapshot
                saveToDisk(snapshot)
                if attempt > 0 {
                    Self.logger.info("crypto fetched on retry \(attempt): \(snapshot.pricesUSD.count) symbols")
                } else {
                    Self.logger.info("crypto fetched: \(snapshot.pricesUSD.count) symbols")
                }
                return snapshot
            } catch {
                lastError = error
                if isTransient(error) {
                    Self.logger.warning("crypto fetch attempt \(attempt + 1) failed (transient): \(error.localizedDescription)")
                    continue
                } else {
                    Self.logger.error("crypto fetch failed (non-retryable): \(error.localizedDescription)")
                    throw error
                }
            }
        }
        let err = lastError ?? URLError(.unknown)
        Self.logger.error("crypto fetch exhausted retries: \(err.localizedDescription)")
        throw err
    }

    private func fetchOnce() async throws -> Snapshot {
        let ids = Self.supportedCoinGeckoIds.values.joined(separator: ",")
        guard let url = URL(string: "https://api.coingecko.com/api/v3/simple/price?ids=\(ids)&vs_currencies=usd") else {
            throw URLError(.badURL)
        }
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FXService.HTTPError(status: http.statusCode)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: [String: Double]] else {
            throw URLError(.cannotDecodeContentData)
        }
        var prices: [String: Double] = [:]
        for (symbol, geckoId) in Self.supportedCoinGeckoIds {
            if let price = json[geckoId]?["usd"] { prices[symbol] = price }
        }
        return Snapshot(pricesUSD: prices, timestamp: Date())
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
        if let httpError = error as? FXService.HTTPError {
            return (500...599).contains(httpError.status)
        }
        return false
    }

    // MARK: - Disk cache

    private func loadFromDisk() -> Snapshot? {
        do {
            let data = try Data(contentsOf: cacheURL)
            return try JSONDecoder().decode(Snapshot.self, from: data)
        } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile {
            return nil   // expected on first launch
        } catch {
            Self.logger.warning("crypto disk cache unreadable, will refetch: \(error.localizedDescription)")
            return nil
        }
    }

    private func saveToDisk(_ snapshot: Snapshot) {
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            Self.logger.warning("crypto disk cache write failed: \(error.localizedDescription)")
        }
    }
}
