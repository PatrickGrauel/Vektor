import Foundation
import Network
import os

/// Tiny `NWPathMonitor` wrapper that posts a notification on every
/// offline → online transition.
///
/// Consumers (`AppModel`) listen for `.tallyNetworkReconnected` and react —
/// typically by re-pulling FX rates and refreshing METAR/TAF/ATIS for any
/// active stations. Without this, an offline → online transition only
/// triggers a refresh on the next 5-minute background tick, leaving the
/// user with stale data for up to 5 minutes after coming back online.
///
/// This is intentionally a singleton: `NWPathMonitor.start(queue:)` opens
/// a system handle, and we want exactly one of them per process.
public final class Reachability: @unchecked Sendable {

    public static let shared = Reachability()

    public static let reconnectedNotification = Notification.Name("tally.network.reconnected")

    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "app.tally.Tally.reachability")
    private let lock = NSLock()
    private var _lastSatisfied: Bool? = nil
    private static let logger = Logger(subsystem: "app.tally.Tally", category: "reachability")

    private init() {
        self.monitor = NWPathMonitor()
        self.monitor.pathUpdateHandler = { [weak self] path in
            self?.handlePathUpdate(path)
        }
        self.monitor.start(queue: self.queue)
    }

    deinit {
        monitor.cancel()
    }

    /// Current reachability state. `nil` means we haven't received the
    /// first path update yet (very brief window at launch).
    public var isOnline: Bool? {
        lock.lock(); defer { lock.unlock() }
        return _lastSatisfied
    }

    private func handlePathUpdate(_ path: NWPath) {
        let satisfied = (path.status == .satisfied)
        lock.lock()
        let previous = _lastSatisfied
        _lastSatisfied = satisfied
        lock.unlock()

        // Log only on transitions to keep the log readable; nominal state
        // is reported once at launch.
        if previous == nil {
            Self.logger.info("path initial: \(satisfied ? "online" : "offline")")
        } else if previous != satisfied {
            Self.logger.info("path transition: \(previous == true ? "online" : "offline") → \(satisfied ? "online" : "offline")")
        }

        // Fire on offline → online transitions only. This is the trigger
        // that consumers care about (a fresh launch already gets data via
        // its own bootstrap path).
        if previous == false && satisfied == true {
            NotificationCenter.default.post(name: Self.reconnectedNotification, object: nil)
        }
    }
}
