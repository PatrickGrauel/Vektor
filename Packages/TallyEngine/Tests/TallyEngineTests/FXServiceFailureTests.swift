import XCTest
@testable import TallyEngine

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
