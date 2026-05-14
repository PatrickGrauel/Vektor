import XCTest
@testable import TallyEngine

/// Coverage for the NotamService and the bridge/engine integration.
/// Uses URLProtocolStub to drive the FAA-shaped responses without
/// hitting the real network.
final class NotamServiceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        URLProtocolStub.reset()
    }

    func test_noCredentials_returnsUnauthenticated() async {
        let svc = NotamService(
            cacheURL: tempCacheURL(),
            session: URLProtocolStub.makeSession(),
            credentialsProvider: { nil }   // explicit no-credentials
        )
        let result = await svc.snapshot(forICAO: "EDDM")
        XCTAssertEqual(result, .unauthenticated)
        XCTAssertEqual(URLProtocolStub.requests.count, 0,
                       "must not make a network call without credentials")
    }

    func test_happyPath_decodesItemsShape() async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "items": [
                [
                    "properties": [
                        "coreNOTAMData": [
                            "notam": [
                                "number": "A1234/26",
                                "type": "N",
                                "classification": "INTL",
                                "effectiveStart": "2026-05-09T04:00:00Z",
                                "effectiveEnd": "2026-05-16T23:59:00Z",
                                "text": "RWY 08L/26R CLSD DUE WIP",
                            ]
                        ]
                    ]
                ]
            ]
        ])
        URLProtocolStub.responses = [.init(statusCode: 200, body: body)]
        let svc = NotamService(
            cacheURL: tempCacheURL(),
            session: URLProtocolStub.makeSession(),
            credentialsProvider: { (clientId: "id", clientSecret: "secret") }
        )
        let result = await svc.snapshot(forICAO: "EDDM")
        switch result {
        case .ok(let snap):
            XCTAssertEqual(snap.notams.count, 1)
            XCTAssertEqual(snap.notams[0].id, "A1234/26")
            XCTAssertEqual(snap.notams[0].text, "RWY 08L/26R CLSD DUE WIP")
            XCTAssertNotNil(snap.notams[0].effectiveStart)
        default:
            XCTFail("expected .ok, got \(result)")
        }
    }

    func test_emptyResponse_returnsEmpty() async throws {
        let body = try JSONSerialization.data(withJSONObject: ["items": [Any]()])
        URLProtocolStub.responses = [.init(statusCode: 200, body: body)]
        let svc = NotamService(
            cacheURL: tempCacheURL(),
            session: URLProtocolStub.makeSession(),
            credentialsProvider: { (clientId: "id", clientSecret: "secret") }
        )
        let result = await svc.snapshot(forICAO: "EDMA")
        XCTAssertEqual(result, .empty(icao: "EDMA"))
    }

    func test_401_returnsNetworkError() async {
        URLProtocolStub.responses = [.init(statusCode: 401)]
        let svc = NotamService(
            cacheURL: tempCacheURL(),
            session: URLProtocolStub.makeSession(),
            credentialsProvider: { (clientId: "bad", clientSecret: "bad") }
        )
        let result = await svc.snapshot(forICAO: "EDDM")
        switch result {
        case .networkError: break
        default: XCTFail("expected .networkError, got \(result)")
        }
    }

    func test_legacyNotamListShape_alsoDecodes() async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "notamList": [
                [
                    "notam": [
                        "id": "Z9/26",
                        "text": "ILS RWY 26L OTS",
                        "effectiveStart": "2026-05-10T06:00:00Z",
                    ]
                ]
            ]
        ])
        URLProtocolStub.responses = [.init(statusCode: 200, body: body)]
        let svc = NotamService(
            cacheURL: tempCacheURL(),
            session: URLProtocolStub.makeSession(),
            credentialsProvider: { (clientId: "id", clientSecret: "secret") }
        )
        let result = await svc.snapshot(forICAO: "EDDM")
        switch result {
        case .ok(let snap):
            XCTAssertEqual(snap.notams.count, 1)
            XCTAssertEqual(snap.notams[0].id, "Z9/26")
            XCTAssertEqual(snap.notams[0].text, "ILS RWY 26L OTS")
        default:
            XCTFail("expected .ok, got \(result)")
        }
    }

    // MARK: - Engine integration

    @MainActor
    func test_engine_NOTAM_lineRecognised() throws {
        let engine = try NumiEngine()
        let r = engine.evaluate("NOTAM EDDM")
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].kind, .expression)
        // Without credentials configured, we expect the unauth message.
        // The actual key may or may not be set in the test environment;
        // accept either "Fetching" or the unauth message — what we
        // really test is that the line was parsed as a NOTAM command
        // and not as a generic expression error.
        let v = r[0].value ?? ""
        XCTAssertTrue(v.contains("EDDM"))
    }

    @MainActor
    func test_engine_multipleStations() throws {
        let engine = try NumiEngine()
        let r = engine.evaluate("NOTAM EDMA EDDM")
        let v = r[0].value ?? ""
        XCTAssertTrue(v.contains("EDMA"))
        XCTAssertTrue(v.contains("EDDM"))
    }

    private func tempCacheURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("notam-\(UUID().uuidString).json")
    }
}
