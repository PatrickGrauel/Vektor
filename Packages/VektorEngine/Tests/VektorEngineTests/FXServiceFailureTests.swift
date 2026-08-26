import XCTest
@testable import VektorEngine

/// Failure-path coverage for FXService. The happy path is implicitly
/// exercised by NumiEngineTests via the calculator integration tests;
/// here we drive the retry / transient-error / cache-resilience paths
/// directly with a programmable URLProtocol stub.
final class FXServiceFailureTests: XCTestCase {

    override func setUp() {
        super.setUp()
        URLProtocolStub.reset()
    }

    /// Two 500s followed by a 200 must succeed on the third attempt and
    /// yield a snapshot. Verifies the retry-with-backoff path.
    func test_retriesTransient5xx_eventuallySucceeds() async throws {
        let okBody = try JSONEncoder().encode(FrankfurterResponse.fixture)
        URLProtocolStub.responses = [
            .init(statusCode: 500),
            .init(statusCode: 503),
            .init(statusCode: 200, body: okBody),
        ]
        let svc = FXService(cacheURL: tempCacheURL(), session: URLProtocolStub.makeSession())
        let snap = try await svc.refresh(using: .frankfurter)
        XCTAssertEqual(snap.ratesPerUSD["EUR"], 0.85)
        XCTAssertEqual(URLProtocolStub.requests.count, 3)
    }

    /// A 4xx response is a bug, not a blip — must NOT retry, and must
    /// surface the error.
    func test_does_not_retry_4xx() async throws {
        URLProtocolStub.responses = [.init(statusCode: 401)]
        let svc = FXService(cacheURL: tempCacheURL(), session: URLProtocolStub.makeSession())
        do {
            _ = try await svc.refresh(using: .frankfurter)
            XCTFail("expected refresh to throw on 4xx")
        } catch {
            // Pass — and crucially only one network request was made.
            XCTAssertEqual(URLProtocolStub.requests.count, 1)
        }
    }

    /// All three retries exhausted → the call throws. No silent success.
    func test_exhaustsRetries_thenThrows() async throws {
        URLProtocolStub.responses = [
            .init(statusCode: 500),
            .init(statusCode: 500),
            .init(statusCode: 500),
        ]
        let svc = FXService(cacheURL: tempCacheURL(), session: URLProtocolStub.makeSession())
        do {
            _ = try await svc.refresh(using: .frankfurter)
            XCTFail("expected refresh to throw after exhausting retries")
        } catch {
            XCTAssertEqual(URLProtocolStub.requests.count, 3)
        }
    }

    /// Corrupt JSON body — NOT a transient error, so it should NOT retry
    /// and should throw cleanly.
    func test_corruptJSON_doesNotRetry() async throws {
        URLProtocolStub.responses = [
            .init(statusCode: 200, body: Data("not json".utf8))
        ]
        let svc = FXService(cacheURL: tempCacheURL(), session: URLProtocolStub.makeSession())
        do {
            _ = try await svc.refresh(using: .frankfurter)
            XCTFail("expected refresh to throw on bad JSON")
        } catch {
            XCTAssertEqual(URLProtocolStub.requests.count, 1)
        }
    }

    /// Disk cache that's unreadable should be treated as a cache miss
    /// (return nil) — no crash, no infinite retry. Then the first
    /// successful fetch populates a fresh on-disk cache.
    func test_corruptDiskCache_isHandledGracefully() async throws {
        let cacheURL = tempCacheURL()
        try Data("garbage".utf8).write(to: cacheURL)
        let okBody = try JSONEncoder().encode(FrankfurterResponse.fixture)
        URLProtocolStub.responses = [.init(statusCode: 200, body: okBody)]
        let svc = FXService(cacheURL: cacheURL, session: URLProtocolStub.makeSession())
        let snap = await svc.snapshot(using: .frankfurter)
        XCTAssertNotNil(snap)
        XCTAssertEqual(snap?.ratesPerUSD["EUR"], 0.85)
    }

    /// ECB-primary merge: the authoritative feed wins on overlap, the
    /// fallback fills the gaps (the RUB-on-ECB case that started this).
    func test_mergeRates_primaryWinsAndFallbackFillsGaps() {
        let ecb: [String: Double] = ["EUR": 0.85, "GBP": 0.74]                 // authoritative majors
        let er:  [String: Double] = ["EUR": 0.88, "RUB": 76.0, "AED": 3.67]    // broad, incl. RUB
        let merged = FXService.mergeRates(primary: ecb, fallback: er)
        XCTAssertEqual(merged["EUR"], 0.85)   // ECB wins on overlap
        XCTAssertEqual(merged["GBP"], 0.74)   // ECB-only code preserved
        XCTAssertEqual(merged["RUB"], 76.0)   // gap filled from er-api
        XCTAssertEqual(merged["AED"], 3.67)
        XCTAssertEqual(merged.count, 4)
    }

    // MARK: - Freshness (fetchedAt) semantics

    /// Disk caches written before `fetchedAt` existed must still decode;
    /// the fetch date falls back to the rate timestamp, so an old cache
    /// reads as stale and gets refreshed instead of crashing the decoder.
    func test_legacyCacheWithoutFetchedAt_decodes() throws {
        let json = #"{"base":"USD","ratesPerUSD":{"EUR":0.9},"timestamp":700000000}"#
        let snap = try JSONDecoder().decode(FXService.Snapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snap.fetchedAt, snap.timestamp)
    }

    /// Rates dated days ago (ECB over a weekend) but FETCHED minutes ago
    /// are fresh — `refreshIfStale` must not touch the network. The same
    /// rates last fetched hours ago are stale — one fetch.
    func test_refreshIfStale_skipsWhenFresh_fetchesWhenStale() async throws {
        let freshCache = tempCacheURL()
        let fresh = FXService.Snapshot(base: "USD", ratesPerUSD: ["EUR": 0.9],
                                       timestamp: Date().addingTimeInterval(-3 * 86400),
                                       fetchedAt: Date())
        try JSONEncoder().encode(fresh).write(to: freshCache)
        let freshSvc = FXService(cacheURL: freshCache, session: URLProtocolStub.makeSession())
        let skipped = try await freshSvc.refreshIfStale(using: .frankfurter)
        XCTAssertNil(skipped)
        XCTAssertEqual(URLProtocolStub.requests.count, 0)

        let staleCache = tempCacheURL()
        let stale = FXService.Snapshot(base: "USD", ratesPerUSD: ["EUR": 0.9],
                                       timestamp: Date().addingTimeInterval(-3 * 86400),
                                       fetchedAt: Date().addingTimeInterval(-2 * 3600))
        try JSONEncoder().encode(stale).write(to: staleCache)
        let okBody = try JSONEncoder().encode(FrankfurterResponse.fixture)
        URLProtocolStub.responses = [.init(statusCode: 200, body: okBody)]
        let staleSvc = FXService(cacheURL: staleCache, session: URLProtocolStub.makeSession())
        let refreshed = try await staleSvc.refreshIfStale(using: .frankfurter)
        XCTAssertEqual(refreshed?.ratesPerUSD["EUR"], 0.85)
        XCTAssertEqual(URLProtocolStub.requests.count, 1)
    }

    /// Attaching a stream over a STALE disk cache must yield the cached
    /// snapshot immediately AND kick a refresh whose result arrives as a
    /// second yield — not sit on stale rates until the polling tick ≥60 s
    /// out (the "yesterday's IDR rate in the screenshot" bug).
    func test_stream_staleCache_yieldsCachedThenFresh() async throws {
        let cacheURL = tempCacheURL()
        let stale = FXService.Snapshot(base: "USD", ratesPerUSD: ["EUR": 0.5],
                                       timestamp: Date().addingTimeInterval(-86400),
                                       fetchedAt: Date().addingTimeInterval(-86400))
        try JSONEncoder().encode(stale).write(to: cacheURL)
        let okBody = try JSONEncoder().encode(FrankfurterResponse.fixture)
        URLProtocolStub.responses = [.init(statusCode: 200, body: okBody)]
        let svc = FXService(cacheURL: cacheURL, session: URLProtocolStub.makeSession())

        var yields: [FXService.Snapshot] = []
        for await snap in await svc.snapshots(using: .frankfurter) {
            yields.append(snap)
            if yields.count == 2 { break }
        }
        XCTAssertEqual(yields[0].ratesPerUSD["EUR"], 0.5)    // cached, instantly
        XCTAssertEqual(yields[1].ratesPerUSD["EUR"], 0.85)   // fresh, right behind it
    }

    // MARK: - Helpers

    private func tempCacheURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("fx-\(UUID().uuidString).json")
    }

    private struct FrankfurterResponse: Encodable {
        let amount: Double
        let base: String
        let date: String
        let rates: [String: Double]
        static let fixture = FrankfurterResponse(
            amount: 1.0,
            base: "USD",
            date: "2026-05-13",
            rates: ["EUR": 0.85, "GBP": 0.74]
        )
    }
}
