import Foundation
import os

/// Synchronous-friendly hot cache for live stock quotes, mirroring the
/// shape of `MetarCacheBridge`. The calculator engine asks the bridge
/// for a cached quote when it sees a `stock AAPL` line; on a miss the
/// bridge schedules a `QuoteService` fetch and posts a notification so
/// the calculator pane re-evaluates and the cached value lands inline.
///
/// Critical property: typing `stock NVDA` one character at a time must
/// NOT burn four API calls (one for each of N, NV, NVD, NVDA). The
/// bridge achieves this with two layered mechanisms:
///
/// 1. **Settle delay (1.5 s).** Every prefetch is scheduled rather
///    than fired immediately. If the task is cancelled before the
///    delay elapses (because the user kept typing and a different
///    symbol superseded it), no network call happens.
/// 2. **Transactional evaluation.** The engine calls
///    `beginEvaluation()` / `endEvaluation()` around each evaluate
///    pass. `endEvaluation` cancels any pending fetches whose symbol
///    is no longer in the document — so as the user types from
///    `stock N` to `stock NVDA`, the bridge cancels N, then NV, then
///    NVD in succession; only NVDA's task is still alive when the
///    1.5 s settle elapses.
///
/// Together: typing a 4-letter ticker at any speed produces exactly
/// one API call, fired ~1.5 s after the user stops typing.
@MainActor
public final class QuoteCacheBridge {
    public static let shared = QuoteCacheBridge()

    public static let notificationName = Notification.Name("tally.quoteCache.updated")

    public struct Entry: Sendable, Equatable {
        public let symbol: String
        public let priceUSD: Double
        public let changeUSD: Double?
        public let fetchedAt: Date
    }

    public enum LastError: Sendable, Equatable {
        case missingAPIKey
        case symbolNotCovered
        case rateLimited
        case transient
    }

    private var entries: [String: Entry] = [:]
    private var errors: [String: LastError] = [:]
    private var pendingTasks: [String: Task<Void, Never>] = [:]

    /// Symbols requested during the current evaluation. Reset by
    /// `beginEvaluation`, drained by `endEvaluation`.
    private var requestedThisEval: Set<String> = []
    private var isEvaluating: Bool = false

    private let service: QuoteService
    private static let logger = Logger(subsystem: "app.tally.Tally", category: "quote-cache-bridge")

    /// How long after the last `prefetch(symbol:)` call to wait before
    /// firing the HTTP request. Long enough that a slow typist (≈1
    /// char/s) finishes their ticker before the network is touched,
    /// short enough that the perceived latency between "I stopped
    /// typing" and "the price appeared" is acceptable.
    private static let settleDelay: TimeInterval = 1.5

    /// How long a cached entry survives before another fetch is
    /// allowed. Quotes change minute-to-minute; 60 s is a good
    /// balance between freshness and API budget.
    private static let refreshTTL: TimeInterval = 60

    public init(service: QuoteService = .shared) {
        self.service = service
    }

    // MARK: - Read

    public func cached(symbol: String) -> Entry? {
        entries[symbol.uppercased()]
    }

    public func lastError(for symbol: String) -> LastError? {
        errors[symbol.uppercased()]
    }

    // MARK: - Evaluation transaction

    /// Open a new evaluation cycle. Inside the cycle, `prefetch` only
    /// records interest; nothing fires until `endEvaluation`.
    public func beginEvaluation() {
        requestedThisEval.removeAll()
        isEvaluating = true
    }

    /// Close the cycle: cancel pending fetches for symbols no longer
    /// requested, and schedule new fetches for newly-interesting ones.
    public func endEvaluation() {
        // Cancel stale pending fetches.
        for (sym, task) in pendingTasks where !requestedThisEval.contains(sym) {
            task.cancel()
            pendingTasks.removeValue(forKey: sym)
        }
        // Schedule fetches for requested symbols that aren't already
        // pending and aren't covered by a still-fresh cache entry.
        let now = Date()
        for sym in requestedThisEval where pendingTasks[sym] == nil {
            if let cached = entries[sym],
               now.timeIntervalSince(cached.fetchedAt) < Self.refreshTTL {
                continue
            }
            pendingTasks[sym] = scheduleFetch(symbol: sym)
        }
        isEvaluating = false
    }

    // MARK: - Write

    /// Record interest in a symbol. Inside a `beginEvaluation` /
    /// `endEvaluation` pair this is a pure book-keeping call — the
    /// actual scheduling happens at `endEvaluation`. Outside one
    /// (legacy callers, tests) the call schedules a fetch directly,
    /// also subject to the cache TTL.
    public func prefetch(symbol: String) {
        let id = symbol.uppercased()
        if isEvaluating {
            requestedThisEval.insert(id)
            return
        }
        let now = Date()
        if let cached = entries[id],
           now.timeIntervalSince(cached.fetchedAt) < Self.refreshTTL {
            return
        }
        if pendingTasks[id] == nil {
            pendingTasks[id] = scheduleFetch(symbol: id)
        }
    }

    // MARK: - Internals

    private func scheduleFetch(symbol: String) -> Task<Void, Never> {
        let service = self.service
        return Task { [weak self] in
            // Settle window. Cancellation during the sleep means the
            // task never reaches the network — which is the whole
            // point: a follow-up evaluation that removes this symbol
            // from `requestedThisEval` calls cancel() on this task.
            try? await Task.sleep(nanoseconds: UInt64(Self.settleDelay * 1_000_000_000))
            if Task.isCancelled { return }

            do {
                if let q = try await service.fetch(symbol: symbol) {
                    await MainActor.run {
                        self?.entries[symbol] = Entry(
                            symbol: q.symbol,
                            priceUSD: q.priceUSD,
                            changeUSD: q.changeUSD,
                            fetchedAt: q.fetchedAt
                        )
                        self?.errors[symbol] = nil
                        self?.pendingTasks.removeValue(forKey: symbol)
                        NotificationCenter.default.post(name: Self.notificationName, object: nil)
                    }
                } else {
                    // Cooldown skip from the service layer — leave any
                    // existing cached value alone.
                    await MainActor.run {
                        self?.pendingTasks.removeValue(forKey: symbol)
                    }
                }
            } catch let err as QuoteService.FetchError {
                let mapped: LastError
                switch err {
                case .missingAPIKey:             mapped = .missingAPIKey
                case .symbolNotCovered:          mapped = .symbolNotCovered
                case .rateLimited:               mapped = .rateLimited
                case .http, .transport, .decode: mapped = .transient
                }
                await MainActor.run {
                    self?.errors[symbol] = mapped
                    self?.pendingTasks.removeValue(forKey: symbol)
                    NotificationCenter.default.post(name: Self.notificationName, object: nil)
                }
            } catch {
                await MainActor.run {
                    self?.errors[symbol] = .transient
                    self?.pendingTasks.removeValue(forKey: symbol)
                }
            }
        }
    }

    // MARK: - Tests

    internal func _reset() {
        entries.removeAll()
        errors.removeAll()
        for (_, task) in pendingTasks { task.cancel() }
        pendingTasks.removeAll()
        requestedThisEval.removeAll()
        isEvaluating = false
    }

    /// Test seam: how many fetches are currently pending. Useful for
    /// asserting that intermediate symbols got cancelled during a
    /// typing sequence.
    internal var _pendingCount: Int { pendingTasks.count }
}
