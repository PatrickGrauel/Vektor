import Foundation
import os

/// Synchronous-friendly wrapper around `MetarService` so the calculator
/// engine can answer `METAR EDDM` / `TAF EDDM` lines without awaiting.
///
/// Pattern mirrors `CityResolver`: a process-wide in-memory snapshot for
/// instant reads, an async `prefetch` that hits the network and posts a
/// `Notification` when fresh data arrives. The calculator pane listens
/// to that notification and re-evaluates.
@MainActor
public final class MetarCacheBridge {
    public static let shared = MetarCacheBridge()

    public static let notificationName = Notification.Name("tally.metarCache.updated")

    public struct Entry {
        public let kind: MetarService.ReportKind
        public let raw: String
        public let fetchedAt: Date
    }

    /// In-memory cache keyed by "KIND|ICAO" (e.g. "METAR|EDDM").
    private var entries: [String: Entry] = [:]
    /// Last time we kicked an upstream fetch for a given key. Used to keep
    /// runaway prefetch calls (one per evaluate cycle, one per minute timer)
    /// from spawning hundreds of concurrent refresh tasks when the cache is
    /// stale.
    private var lastAttempt: [String: Date] = [:]
    /// Last time the caller actually *used* a cached value (read or asked
    /// for a prefetch). Distinct from `lastAttempt`: lets us tell apart
    /// "this station was actively referenced in the last hour" from "we
    /// tried to refresh this 5 min ago but no one has looked at it since".
    /// Drives both LRU eviction and the active-station refresh job.
    private var lastUsed: [String: Date] = [:]
    private let service: MetarService

    /// Minimum interval (seconds) between upstream refresh attempts for the
    /// same station+kind. Picked to be a fraction of the shortest METAR
    /// cadence (30 min international) so we always check at least a few
    /// times per cycle but never hammer the API.
    private static let attemptCooldown: TimeInterval = 5 * 60     // 5 minutes
    /// After how long a cache entry becomes stale enough that an attempt
    /// is worth making (subject to the cooldown above).
    private static let staleAfter: TimeInterval = 5 * 60          // 5 minutes
    /// Hard cap on in-memory entries. The on-disk `metar.cache.json` is
    /// the source of truth for older lookups; this bridge is a hot layer.
    public static let maxEntries: Int = 25
    /// An entry's `lastUsed` older than this window is fair game for
    /// eviction even when we're under `maxEntries`. Bounded so the bridge
    /// doesn't hold onto stations no one has looked at in hours.
    private static let idleEvictionAfter: TimeInterval = 60 * 60  // 1 hour
    /// Periodic sweep interval for the idle-eviction tick.
    private static let evictionTickInterval: TimeInterval = 15 * 60

    private var evictionTask: Task<Void, Never>?

    /// Tracks in-flight prefetch Tasks per key. Prevents a second prefetch
    /// from spawning while the first is still in flight (the per-key
    /// cooldown handles repeated calls *after* completion, but doesn't
    /// stop racing during the network roundtrip). Also gives us a clean
    /// cancellation hook on teardown.
    private var inFlight: [String: Task<Void, Never>] = [:]

    private static let logger = Logger(subsystem: "app.tally.Tally", category: "metar-cache-bridge")

    init(service: MetarService = .shared) {
        self.service = service
        startEvictionLoop()
    }

    deinit {
        evictionTask?.cancel()
        for (_, task) in inFlight { task.cancel() }
    }

    public func cached(kind: MetarService.ReportKind, icao: String) -> Entry? {
        // Canonicalise so `JFK` and `KJFK` hit the same cache entry.
        guard let canonical = AirportCodeMap.canonicalICAO(from: icao) else {
            return nil
        }
        let key = Self.key(kind: kind, icao: canonical)
        if let entry = entries[key] {
            lastUsed[key] = Date()
            return entry
        }
        return nil
    }

    /// Kick off an async fetch. Safe to call on every evaluate cycle — we
    /// dedupe via a per-key cooldown so the network only sees one refresh
    /// attempt per 5 minutes regardless of how often the caller asks.
    /// On success we update the cache and post a notification so the
    /// engine re-evaluates and the gutter shows the fresh data.
    public func prefetch(kind: MetarService.ReportKind, icao: String) {
        // Canonicalise so a 3-letter IATA gets resolved to its 4-letter
        // ICAO before we touch the cache, the cooldown table, or the
        // network. Unknown / malformed codes short-circuit silently —
        // the engine pane shows the placeholder, never spins forever.
        guard let id = AirportCodeMap.canonicalICAO(from: icao) else {
            return
        }
        let key = Self.key(kind: kind, icao: id)
        let now = Date()

        // The caller is asking about this station — mark it active even if
        // we end up short-circuiting on cooldown.
        lastUsed[key] = now

        // Skip if the cache is still fresh.
        if let existing = entries[key],
           now.timeIntervalSince(existing.fetchedAt) < Self.staleAfter {
            return
        }
        // Skip if we attempted recently (regardless of success), so racing
        // callers don't fan out.
        if let last = lastAttempt[key],
           now.timeIntervalSince(last) < Self.attemptCooldown {
            return
        }
        lastAttempt[key] = now

        // Skip if a prefetch is already in flight for this key. Without
        // this guard, two rapid evaluate cycles can both pass the
        // cooldown check (the cooldown updates BEFORE the network
        // roundtrip starts) and race each other.
        if let existing = inFlight[key], !existing.isCancelled {
            return
        }

        let service = self.service
        let task = Task { [weak self] in
            guard let self else { return }
            let serviceEntry: MetarService.Entry?
            switch kind {
            case .metar: serviceEntry = await service.metar(for: id)
            case .taf:   serviceEntry = await service.taf(for: id)
            case .atis:  serviceEntry = await service.atis(for: id)
            }
            // Always clear the in-flight slot, even on cancellation /
            // empty response — leaving a stale entry would block future
            // prefetches forever.
            await MainActor.run { self.inFlight[key] = nil }
            guard let s = serviceEntry, !s.raw.isEmpty else { return }
            let entry = Entry(kind: kind, raw: s.raw, fetchedAt: s.fetchedAt)
            await MainActor.run {
                self.entries[key] = entry
                self.enforceCap()
                NotificationCenter.default.post(name: Self.notificationName, object: nil)
            }
        }
        inFlight[key] = task
    }

    /// Stations the background refresh job should warm: anything used
    /// within the last `idleEvictionAfter` window. Returns `(kind, icao)`
    /// pairs decoded from the cache keys.
    public func activeStations() -> [(MetarService.ReportKind, String)] {
        let cutoff = Date().addingTimeInterval(-Self.idleEvictionAfter)
        return lastUsed.compactMap { key, used -> (MetarService.ReportKind, String)? in
            guard used >= cutoff else { return nil }
            return Self.decode(key: key)
        }
    }

    /// Exposed for tests + Settings diagnostics.
    public var entryCount: Int { entries.count }

    /// Drop entries whose `lastUsed` is older than the idle window. Runs
    /// on the eviction tick AND opportunistically when we breach the cap.
    public func evictIdle() {
        let cutoff = Date().addingTimeInterval(-Self.idleEvictionAfter)
        let idleKeys = lastUsed.filter { $0.value < cutoff }.map(\.key)
        for k in idleKeys {
            entries.removeValue(forKey: k)
            lastAttempt.removeValue(forKey: k)
            lastUsed.removeValue(forKey: k)
        }
    }

    /// If over `maxEntries`, drop the least-recently-used entries until
    /// we're back at the cap. Stations with no `lastUsed` (shouldn't
    /// happen, but defensive) are evicted first.
    private func enforceCap() {
        guard entries.count > Self.maxEntries else { return }
        let sorted = entries.keys.sorted {
            (lastUsed[$0] ?? .distantPast) < (lastUsed[$1] ?? .distantPast)
        }
        let toDrop = sorted.prefix(entries.count - Self.maxEntries)
        for k in toDrop {
            entries.removeValue(forKey: k)
            lastAttempt.removeValue(forKey: k)
            lastUsed.removeValue(forKey: k)
        }
    }

    private func startEvictionLoop() {
        evictionTask?.cancel()
        evictionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.evictionTickInterval * 1_000_000_000))
                await MainActor.run { self?.evictIdle() }
            }
        }
    }

    /// Test seam: insert an entry directly without going through the
    /// network. Bumps `lastUsed` and runs the cap check, so eviction
    /// behavior can be exercised without spinning up URLSession mocks.
    internal func _testInsert(kind: MetarService.ReportKind,
                              icao: String,
                              raw: String = "raw",
                              fetchedAt: Date = Date(),
                              lastUsed used: Date? = nil) {
        let key = Self.key(kind: kind, icao: icao)
        entries[key] = Entry(kind: kind, raw: raw, fetchedAt: fetchedAt)
        lastUsed[key] = used ?? fetchedAt
        enforceCap()
    }

    /// Test seam: read the `lastUsed` timestamp for an entry.
    internal func _testLastUsed(kind: MetarService.ReportKind, icao: String) -> Date? {
        lastUsed[Self.key(kind: kind, icao: icao)]
    }

    private static func key(kind: MetarService.ReportKind, icao: String) -> String {
        "\(kind.rawValue.uppercased())|\(icao.uppercased())"
    }

    private static func decode(key: String) -> (MetarService.ReportKind, String)? {
        let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let kind = MetarService.ReportKind(rawValue: parts[0].lowercased())
        else { return nil }
        return (kind, parts[1])
    }
}
