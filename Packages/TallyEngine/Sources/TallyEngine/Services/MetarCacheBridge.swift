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

    /// Hard anti-hammer guard. We will NEVER fire more than one
    /// refresh per key inside this window — protects the upstream API
    /// from a keystroke-rate flood when the user is typing in the
    /// calculator (every keystroke triggers a re-evaluate that calls
    /// `prefetch`).
    private static let minimumFetchInterval: TimeInterval = 30
    /// Soft cap on "quiet" time between proactive fetches. Even if the
    /// upstream issuance schedule says the cached entry is still the
    /// latest expected report, retry after this window to catch off-
    /// schedule updates (SPECI METARs, mid-cycle TAF amendments, ATIS
    /// letter rotations). Keep small enough that a stale entry can't
    /// linger more than a few minutes longer than it should.
    private static let maxQuietWindow: TimeInterval = 10 * 60     // 10 minutes
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

    /// Kick off an async fetch. Safe to call on every evaluate cycle —
    /// we dedupe via per-key cooldowns so the network only sees one
    /// attempt per `minimumFetchInterval` regardless of how often the
    /// caller asks. On success we update the cache and post a
    /// notification so the engine re-evaluates and the gutter shows
    /// the fresh data.
    ///
    /// Staleness decision (in order):
    ///   1. Hard anti-hammer: any fetch attempt in the last 30 s ⇒ skip.
    ///   2. Soft cap: if last successful fetch ≥ 10 min ago ⇒ fetch.
    ///   3. Issuance schedule: ask `NumiEngine.nextExpectedIssuance` —
    ///      if the upstream issuance window for this kind has passed
    ///      since the cached entry's observation time ⇒ fetch.
    ///   4. Otherwise ⇒ skip (cached entry IS the latest expected).
    ///
    /// Critically, staleness is judged against the cached entry's
    /// *observation time*, not its local fetch time. Previously the
    /// bridge used fetch time, which meant once we successfully
    /// fetched an old report (e.g. an overnight TAF from 18:00 UTC
    /// for an airport closed at night) the bridge would refuse to
    /// re-fetch for 5 minutes — and on every subsequent re-evaluate
    /// the cooldown reset, locking the bridge onto the stale entry
    /// for the rest of the process lifetime. The user could not
    /// force a refresh except by quitting and relaunching.
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

        // (1) Hard anti-hammer guard — applies to BOTH attempts and
        //     successful fetches.
        if let last = lastAttempt[key],
           now.timeIntervalSince(last) < Self.minimumFetchInterval {
            return
        }
        if let existing = entries[key],
           now.timeIntervalSince(existing.fetchedAt) < Self.minimumFetchInterval {
            return
        }

        // (2) Soft cap: even when the issuance schedule says the cached
        //     entry is still current, force a refresh if we haven't
        //     checked in a while. Catches off-schedule updates.
        let sinceFetch: TimeInterval? = entries[key].map { now.timeIntervalSince($0.fetchedAt) }
        let withinQuietWindow = (sinceFetch ?? .infinity) < Self.maxQuietWindow

        // (3) Issuance schedule check: only applicable inside the soft cap.
        if withinQuietWindow, let existing = entries[key] {
            let referenceTime = NumiEngine.observationTime(in: existing.raw) ?? existing.fetchedAt
            let nextIssuance = NumiEngine.nextExpectedIssuance(
                for: kind, rawCached: existing.raw, after: referenceTime
            )
            if nextIssuance > now {
                // Upstream hasn't published a new report yet by its own
                // cadence — the cached entry IS the latest. Skip.
                return
            }
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
            // Use `service.refresh(…)` directly rather than the
            // `service.metar/taf/atis(for:)` convenience wrappers. The
            // wrappers do stale-while-revalidate: when the underlying
            // cache is older than 5 min they return the CACHED entry
            // and silently fire a background refresh. That's the wrong
            // semantic here — the bridge has its own 5-min cooldown
            // (already passed above), so reaching this point means we
            // genuinely want a fresh fetch. The previous wrappers
            // caused the bridge cache to lock onto stale data for the
            // rest of the process lifetime (e.g. a 12-hour-old TAF for
            // EDDM persisting after a new TAF issuance, because the
            // background refresh only updated MetarService's cache,
            // never the bridge).
            let serviceEntry: MetarService.Entry?
            do {
                serviceEntry = try await service.refresh(icao: id, kind: kind)
            } catch {
                Self.logger.warning("prefetch \(kind.rawValue) \(id) failed: \(error.localizedDescription)")
                serviceEntry = nil
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
