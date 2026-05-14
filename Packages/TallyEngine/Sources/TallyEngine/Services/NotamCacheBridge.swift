import Foundation
import os

/// Main-actor wrapper around `NotamService` so the calculator engine
/// can answer `NOTAM EDDM` lines without `await`. Mirrors
/// `MetarCacheBridge` in shape: a per-ICAO hot cache with a 30-second
/// fetch cooldown, plus an in-flight task table so racing evaluate
/// cycles share one network call. Posts
/// `MetarCacheBridge.notificationName`-style notifications when a new
/// snapshot lands so the calculator re-evaluates.
@MainActor
public final class NotamCacheBridge {

    public static let shared = NotamCacheBridge()

    public static let notificationName = Notification.Name("tally.notamCache.updated")

    /// Convenience union of states so the engine can render
    /// "Fetching…", "set up your FAA key", "no NOTAMs", or the actual
    /// list without each call site re-implementing the dispatch.
    public enum State {
        case pending             // fetch in flight, no cached snapshot yet
        case ok(NotamService.Snapshot)
        case empty(icao: String) // upstream returned no NOTAMs
        case unauthenticated     // user hasn't set their FAA API key
        case error(String)       // network error, no cached fallback
    }

    private static let logger = Logger(subsystem: "app.tally.Tally", category: "notam-cache-bridge")
    private static let minimumFetchInterval: TimeInterval = 30

    private let service: NotamService
    private var entries: [String: State] = [:]
    private var lastAttempt: [String: Date] = [:]
    private var inFlight: [String: Task<Void, Never>] = [:]

    public init(service: NotamService = NotamService()) {
        self.service = service
    }

    deinit {
        for (_, t) in inFlight { t.cancel() }
    }

    public func cached(icao: String) -> State? {
        entries[icao.uppercased()]
    }

    public func prefetch(icao: String) {
        let key = icao.uppercased()
        let now = Date()

        // Hard 30-second cooldown so a 4-Hz keystroke evaluate cycle
        // doesn't fan out fetches.
        if let last = lastAttempt[key],
           now.timeIntervalSince(last) < Self.minimumFetchInterval {
            return
        }
        if let existing = inFlight[key], !existing.isCancelled { return }
        lastAttempt[key] = now
        // If we don't have a state yet, mark pending so the UI can
        // show "Fetching…" while the network is in flight.
        if entries[key] == nil {
            entries[key] = .pending
        }

        let service = self.service
        let task = Task { [weak self] in
            guard let self else { return }
            let result = await service.snapshot(forICAO: key)
            await MainActor.run {
                self.inFlight[key] = nil
                switch result {
                case .ok(let snap):
                    self.entries[key] = .ok(snap)
                case .empty(let icao):
                    self.entries[key] = .empty(icao: icao)
                case .unauthenticated:
                    self.entries[key] = .unauthenticated
                case .networkError(let msg):
                    // Keep any prior cached snapshot rather than
                    // overwrite with an error state — the engine
                    // already shows stale data with a label.
                    if case .ok = self.entries[key] {
                        // leave as-is
                    } else {
                        self.entries[key] = .error(msg)
                    }
                }
                NotificationCenter.default.post(name: Self.notificationName, object: nil)
            }
        }
        inFlight[key] = task
    }
}
