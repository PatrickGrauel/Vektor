import XCTest
@testable import VektorEngine

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

    /// math.js reads `: N` as the range `1:N`; a pasted `: 92004301010121`
    /// used to build 92 trillion elements and hang the main thread.
    func test_hugeRange_doesNotHang() throws {
        let engine = try NumiEngine()
        let r = engine.evaluate(": 92004301010121\n1:1e15\nsum(1:10)")
        XCTAssertEqual(r.count, 3)
        XCTAssertEqual(r[2].value, "55")
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

    // MARK: - Multi-station METAR / TAF / ATIS parsing

    func test_metar_singleStation_unchanged() throws {
        let engine = try NumiEngine()
        let r = engine.evaluate("METAR EDMA")
        XCTAssertEqual(r.count, 1)
        // Pre-fetch: kind is .expression and value is either the
        // "Fetching…" placeholder or, if the bridge has a prior cache hit,
        // the raw report. Either way the line should NOT be parsed as a
        // generic expression error.
        XCTAssertEqual(r[0].kind, .expression)
        XCTAssertNotNil(r[0].value)
    }

    func test_metar_multipleStations_recognised() throws {
        let engine = try NumiEngine()
        let r = engine.evaluate("METAR EDMA EDMO EDDM")
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].kind, .expression)
        XCTAssertNotNil(r[0].value)
        // On a fresh launch with no cache, the value is three "Fetching…"
        // placeholders joined by newlines — verify the multi-line shape.
        let v = r[0].value ?? ""
        let lines = v.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3, "expected three lines, got: \(v)")
        XCTAssertTrue(lines.allSatisfy { $0.contains("EDMA") || $0.contains("EDMO") || $0.contains("EDDM") })
    }

    func test_taf_multipleStations_recognised() throws {
        let engine = try NumiEngine()
        let r = engine.evaluate("TAF KSFO KLAX KJFK")
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].kind, .expression)
        let v = r[0].value ?? ""
        let lines = v.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3, "expected three TAF lines, got: \(v)")
    }

    func test_metar_invalidShape_fallsThrough() throws {
        let engine = try NumiEngine()
        // Trailing junk that doesn't look like an ICAO (numbers, too long)
        // must NOT match the multi-station pattern. The shape would
        // otherwise quietly accept anything alphabetic and start fetching
        // for it.
        let r1 = engine.evaluate("METAR EDMA EDDM 123")           // numbers → not ICAO
        XCTAssertFalse((r1.first?.value ?? "").contains("Fetching METAR EDMA"))

        let r2 = engine.evaluate("METAR EDMA TOOLONG12")          // 8-char token → not ICAO
        XCTAssertFalse((r2.first?.value ?? "").contains("Fetching METAR EDMA"))

        let r3 = engine.evaluate("METAR EDMA in USD")             // "in USD" tail
        XCTAssertFalse((r3.first?.value ?? "").contains("Fetching METAR EDMA"))
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
