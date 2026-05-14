import XCTest
@testable import TallyEngine

/// Crash-resistance tests for NumiEngine. Garbage / pathological input
/// must NOT bring the engine down — every call should return a coherent
/// `[LineResult]` matching `lines.count`.
@MainActor
final class NumiEngineCrashTests: XCTestCase {

    func test_emptyDocument() throws {
        let engine = try NumiEngine()
        let r = engine.evaluate("")
        // One blank line is one result.
        XCTAssertEqual(r.count, 1)
    }

    func test_unicodeOnly() throws {
        let engine = try NumiEngine()
        let r = engine.evaluate("🚀✈️🛬\n汉字\n")
        XCTAssertEqual(r.count, 3)
    }

    func test_deeplyNestedParens() throws {
        let engine = try NumiEngine()
        let nest = String(repeating: "(", count: 200) + "1" + String(repeating: ")", count: 200)
        let r = engine.evaluate(nest)
        XCTAssertEqual(r.count, 1)
    }

    func test_largeDocument() throws {
        let engine = try NumiEngine()
        // 500 lines of mixed valid/invalid expressions.
        let body = (0..<500).map { i in i.isMultiple(of: 2) ? "\(i) + \(i)" : "garbage \(i)" }.joined(separator: "\n")
        let r = engine.evaluate(body)
        XCTAssertEqual(r.count, 500)
    }

    func test_currencyConversionWithNoFXLoaded_returnsExpression() throws {
        let engine = try NumiEngine()
        // Without applyFX, EUR is registered as a 1:1 placeholder via
        // ensureCurrency. The engine should still produce an expression
        // result, NOT crash.
        let r = engine.evaluate("25 EUR in USD")
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].kind, .expression)
        XCTAssertNotNil(r[0].value)
    }

    func test_observationTime_garbageInput_returnsNil() {
        XCTAssertNil(NumiEngine.observationTime(in: "no zulu stamp here"))
        XCTAssertNil(NumiEngine.observationTime(in: ""))
        XCTAssertNil(NumiEngine.observationTime(in: "9999Z"))            // too short
        XCTAssertNil(NumiEngine.observationTime(in: "32 24 60 Z"))       // out-of-range fields with spaces
    }

    func test_tafValidityHours_garbageInput_returnsNil() {
        XCTAssertNil(NumiEngine.tafValidityHours(in: ""))
        XCTAssertNil(NumiEngine.tafValidityHours(in: "no validity here"))
        XCTAssertNil(NumiEngine.tafValidityHours(in: "1325/9999"))       // bad end-hour
    }

    // MARK: - nextExpectedIssuance

    func test_nextExpectedIssuance_metar_alwaysFuture() {
        let now = Date()
        let next = NumiEngine.nextExpectedIssuance(for: .metar, rawCached: nil, after: now)
        XCTAssertGreaterThan(next, now)
        // Shouldn't be more than ~1 hour out (next :55 + 30 s).
        XCTAssertLessThanOrEqual(next.timeIntervalSince(now), 3600 + 30)
    }

    func test_nextExpectedIssuance_taf_alignsToCadence() {
        let now = Date()
        let next = NumiEngine.nextExpectedIssuance(for: .taf, rawCached: nil, after: now)
        XCTAssertGreaterThan(next, now)
        // 24-h validity → 6-h cadence → next slot is ≤ 6 h + 30 s out.
        XCTAssertLessThanOrEqual(next.timeIntervalSince(now), 6 * 3600 + 60)
    }

    func test_nextExpectedIssuance_atis_usesObservationAnchor() {
        let now = Date()
        // Cached observation 2 h ago → next issuance ~ now (60 min after
        // observation has already passed, so we clamp to now+30 s+30 s).
        let twoHoursAgo = now.addingTimeInterval(-2 * 3600)
        let cal = Calendar(identifier: .gregorian)
        var c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: twoHoursAgo)
        // Build a synthetic METAR-style stamp matching that time so
        // observationTime() can find it. Format: DDHHMMZ.
        let stamp = String(format: "%02d%02d%02dZ", c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
        let raw = "ATIS \(stamp) ALFA"
        let next = NumiEngine.nextExpectedIssuance(for: .atis, rawCached: raw, after: now)
        XCTAssertGreaterThan(next, now)
    }
}
