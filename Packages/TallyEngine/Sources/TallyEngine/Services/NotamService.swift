import Foundation
import os

/// Light wrapper around the FAA NOTAM Search API
/// (https://external-api.faa.gov/notamapi/v1/notams).
///
/// **Setup:** users register a free developer account at api.faa.gov
/// and create an app, which yields a `client_id` and `client_secret`.
/// Both are stored in UserDefaults under
/// `tally.notam.faaClientId` / `tally.notam.faaClientSecret`. With
/// no credentials configured `snapshot(forICAO:)` returns a
/// dedicated `.unauthenticated` value so the UI can prompt the user
/// to add their key.
///
/// The API aggregates ICAO data world-wide, so requesting EDDM,
/// EDMA, or KSFO all work through the same endpoint.
public actor NotamService {

    public struct NotamRecord: Codable, Sendable, Equatable {
        public let id: String                 // e.g. "A1234/26" (numbering varies)
        public let icao: String
        public let type: String?              // N (new) / R (replace) / C (cancel)
        public let classification: String?    // INTL / MIL / DOM / …
        public let effectiveStart: Date?
        public let effectiveEnd: Date?        // nil = permanent / "PERM" / "UFN"
        /// E-line free text — the NOTAM body. Usually heavily
        /// abbreviated ("RWY 08L/26R CLSD WIE TIL UFN"). v1: we
        /// display raw, no expansion.
        public let text: String
    }

    public struct Snapshot: Codable, Sendable, Equatable {
        public let icao: String
        public let notams: [NotamRecord]
        public let fetchedAt: Date
    }

    /// Disposition of a `snapshot(forICAO:)` call. The
    /// `.unauthenticated` and `.networkError` cases let
    /// the UI distinguish "you need to set up an API key" from
    /// "the call failed" so the message can be appropriately
    /// actionable.
    public enum Result: Sendable, Equatable {
        case ok(Snapshot)
        case unauthenticated
        case networkError(String)
        case empty(icao: String)       // API returned 200 with no NOTAMs

        public static func == (lhs: Result, rhs: Result) -> Bool {
            switch (lhs, rhs) {
            case (.unauthenticated, .unauthenticated): return true
            case (.empty(let l), .empty(let r)): return l == r
            case (.networkError(let l), .networkError(let r)): return l == r
            case (.ok(let l), .ok(let r)): return l == r
            default: return false
            }
        }
    }

    private static let logger = Logger(subsystem: "app.tally.Tally", category: "notam")
    private static let requestTimeout: TimeInterval = 15
    private static let cacheTTL: TimeInterval = 5 * 60   // 5 minutes

    /// Endpoint. Configurable for tests / debugging — defaults to the
    /// production FAA URL.
    public let endpoint: URL
    private let session: URLSession
    private let credentialsProvider: @Sendable () -> (clientId: String, clientSecret: String)?
    private let cacheURL: URL
    private var inMemory: [String: Snapshot] = [:]

    public init(endpoint: URL = URL(string: "https://external-api.faa.gov/notamapi/v1/notams")!,
                cacheURL: URL? = nil,
                session: URLSession? = nil,
                credentialsProvider: (@Sendable () -> (clientId: String, clientSecret: String)?)? = nil) {
        self.endpoint = endpoint
        let fm = FileManager.default
        let dir = (try? fm.url(for: .cachesDirectory, in: .userDomainMask,
                               appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.cacheURL = cacheURL ?? dir.appendingPathComponent("notam.cache.json")
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = Self.requestTimeout
            cfg.timeoutIntervalForResource = Self.requestTimeout * 2
            self.session = URLSession(configuration: cfg)
        }
        self.credentialsProvider = credentialsProvider ?? Self.defaultCredentialsProvider
        self.inMemory = Self.loadFromDisk(at: self.cacheURL)
    }

    /// Reads credentials from UserDefaults. Returns nil if either
    /// value is missing or empty.
    private static let defaultCredentialsProvider: @Sendable () -> (clientId: String, clientSecret: String)? = {
        let id = UserDefaults.standard.string(forKey: "tally.notam.faaClientId") ?? ""
        let secret = UserDefaults.standard.string(forKey: "tally.notam.faaClientSecret") ?? ""
        guard !id.isEmpty, !secret.isEmpty else { return nil }
        return (clientId: id, clientSecret: secret)
    }

    // MARK: - Public API

    public func snapshot(forICAO icao: String) async -> Result {
        let key = icao.uppercased()
        if let cached = inMemory[key],
           Date().timeIntervalSince(cached.fetchedAt) < Self.cacheTTL {
            return .ok(cached)
        }
        guard let creds = credentialsProvider() else {
            return .unauthenticated
        }
        do {
            let snap = try await fetch(icao: key, clientId: creds.clientId, clientSecret: creds.clientSecret)
            inMemory[key] = snap
            saveToDisk()
            if snap.notams.isEmpty {
                return .empty(icao: key)
            }
            return .ok(snap)
        } catch {
            Self.logger.error("fetch \(key) failed: \(error.localizedDescription)")
            // Fall back to a cached snapshot if we have ANY — even one
            // past its TTL is better than nothing.
            if let cached = inMemory[key] {
                Self.logger.info("returning stale cache for \(key)")
                return .ok(cached)
            }
            return .networkError(error.localizedDescription)
        }
    }

    // MARK: - Network

    private func fetch(icao: String, clientId: String, clientSecret: String) async throws -> Snapshot {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "icaoLocation", value: icao),
            URLQueryItem(name: "pageSize", value: "50"),
            URLQueryItem(name: "pageNum", value: "1"),
        ]
        guard let url = components.url else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        // FAA NOTAM Search auth: client_id / client_secret as headers.
        req.setValue(clientId, forHTTPHeaderField: "client_id")
        req.setValue(clientSecret, forHTTPHeaderField: "client_secret")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw NotamError.unauthorized(http.statusCode)
            }
            if !(200..<300).contains(http.statusCode) {
                throw NotamError.http(http.statusCode)
            }
        }
        return try decode(data: data, icao: icao)
    }

    /// FAA returns a (sometimes nested) JSON document. We extract the
    /// minimum fields we care about and tolerate missing keys — the
    /// response schema has shifted between FAA API revisions and we
    /// don't want a benign change to lock pilots out of NOTAMs.
    private func decode(data: Data, icao: String) throws -> Snapshot {
        let json = try JSONSerialization.jsonObject(with: data)
        // The API returns `{ items: [{ properties: { coreNOTAMData: { notam: { … } } } }] }`.
        // We also accept `{ notamList: [ { notam: { … } } ] }` as a legacy shape.
        var rawNotams: [[String: Any]] = []
        if let obj = json as? [String: Any] {
            if let items = obj["items"] as? [[String: Any]] {
                for item in items {
                    let props = item["properties"] as? [String: Any] ?? item
                    if let core = props["coreNOTAMData"] as? [String: Any],
                       let n = core["notam"] as? [String: Any] {
                        rawNotams.append(n)
                    } else if let n = props["notam"] as? [String: Any] {
                        rawNotams.append(n)
                    } else {
                        rawNotams.append(props)
                    }
                }
            } else if let list = obj["notamList"] as? [[String: Any]] {
                for item in list {
                    if let n = item["notam"] as? [String: Any] {
                        rawNotams.append(n)
                    } else {
                        rawNotams.append(item)
                    }
                }
            }
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFrac = ISO8601DateFormatter()
        isoNoFrac.formatOptions = [.withInternetDateTime]

        func parseDate(_ any: Any?) -> Date? {
            guard let s = any as? String, !s.isEmpty else { return nil }
            return iso.date(from: s) ?? isoNoFrac.date(from: s)
        }

        let records: [NotamRecord] = rawNotams.compactMap { raw in
            let id = (raw["number"] as? String)
                  ?? (raw["id"] as? String)
                  ?? "—"
            let type = raw["type"] as? String
            let classification = raw["classification"] as? String
            let effectiveStart = parseDate(raw["effectiveStart"])
                              ?? parseDate(raw["activeFromDate"])
            let effectiveEnd = parseDate(raw["effectiveEnd"])
                            ?? parseDate(raw["activeToDate"])
            let text = (raw["text"] as? String)
                     ?? (raw["icaoMessage"] as? String)
                     ?? (raw["traditionalMessage"] as? String)
                     ?? ""
            return NotamRecord(
                id: id,
                icao: icao,
                type: type,
                classification: classification,
                effectiveStart: effectiveStart,
                effectiveEnd: effectiveEnd,
                text: text.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        return Snapshot(icao: icao, notams: records, fetchedAt: Date())
    }

    enum NotamError: Error, LocalizedError {
        case unauthorized(Int)
        case http(Int)
        var errorDescription: String? {
            switch self {
            case .unauthorized(let s): return "FAA API rejected credentials (HTTP \(s))"
            case .http(let s):         return "FAA API HTTP \(s)"
            }
        }
    }

    // MARK: - Disk cache

    private static func loadFromDisk(at url: URL) -> [String: Snapshot] {
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([String: Snapshot].self, from: data)
        } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile {
            return [:]
        } catch {
            logger.warning("notam disk cache unreadable: \(error.localizedDescription)")
            return [:]
        }
    }

    private func saveToDisk() {
        do {
            let data = try JSONEncoder().encode(inMemory)
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            Self.logger.warning("notam disk cache write failed: \(error.localizedDescription)")
        }
    }
}
