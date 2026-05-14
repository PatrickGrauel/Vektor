import XCTest
@testable import TallyEngine

/// Failure-path coverage for MetarService — same pattern as FXServiceFailureTests
/// (programmable URLProtocol stub, no real network).
final class MetarServiceFailureTests: XCTestCase {

    override func setUp() {
        super.setUp()
        URLProtocolStub.reset()
    }

    func test_retriesTransient5xx() async throws {
        URLProtocolStub.responses = [
            .init(statusCode: 502),
            .init(statusCode: 503),
            .init(statusCode: 200, body: Data("METAR EDMA 131850Z 28004KT CAVOK 12/02 Q1004 NOSIG".utf8)),
        ]
        let svc = MetarService(cacheURL: tempCacheURL(), session: URLProtocolStub.makeSession())
        let entry = try await svc.refresh(icao: "EDMA", kind: .metar)
        XCTAssertTrue(entry.raw.contains("EDMA"))
        XCTAssertEqual(URLProtocolStub.requests.count, 3)
    }

    func test_4xx_doesNotRetry() async throws {
        URLProtocolStub.responses = [.init(statusCode: 404)]
        let svc = MetarService(cacheURL: tempCacheURL(), session: URLProtocolStub.makeSession())
        do {
            _ = try await svc.refresh(icao: "ZZZZ", kind: .metar)
            XCTFail("expected throw on 4xx")
        } catch {
            XCTAssertEqual(URLProtocolStub.requests.count, 1)
        }
    }

    func test_invalidICAO_failsFast() async throws {
        // Empty / non-alphanumeric input is rejected before any network call.
        let svc = MetarService(cacheURL: tempCacheURL(), session: URLProtocolStub.makeSession())
        do {
            _ = try await svc.refresh(icao: "", kind: .metar)
            XCTFail("expected throw on empty ICAO")
        } catch {
            XCTAssertEqual(URLProtocolStub.requests.count, 0)
        }
    }

    /// ATIS endpoint returning a non-JSON body (datis.clowd.io behaviour
    /// for unsupported airports) must NOT retry — the body explains the
    /// situation and we surface that to the user.
    func test_atis_nonJSON_returnsExplanation() async throws {
        URLProtocolStub.responses = [
            .init(statusCode: 200, body: Data("Not a JSON array".utf8))
        ]
        let svc = MetarService(cacheURL: tempCacheURL(), session: URLProtocolStub.makeSession())
        let entry = try await svc.refresh(icao: "EDMA", kind: .atis)
        XCTAssertTrue(entry.raw.contains("ATIS unavailable"))
        XCTAssertEqual(URLProtocolStub.requests.count, 1)
    }

    private func tempCacheURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("metar-\(UUID().uuidString).json")
    }
}
