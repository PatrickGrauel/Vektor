import XCTest
@testable import VektorEngine
import VektorAviation

/// End-to-end coverage for the new `distance` and `sun` commands.
/// Uses the bundled OurAirports CSV for coordinates, so these tests
/// run fully offline.
@MainActor
final class DistanceSunTests: XCTestCase {

    // MARK: - Distance + bearing

    func test_distance_EDDM_to_EDMA_inNM() throws {
        let engine = try NumiEngine()
        let r = engine.evaluate("distance EDDM to EDMA")
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].kind, .expression)
        let v = r[0].value ?? ""
        // EDDM ↔ EDMA is roughly 35 NM (Munich to Augsburg, ~65 km).
        // The default unit is NM; the line ends with the bearing.
        XCTAssertTrue(v.contains("NM"), "expected NM in: \(v)")
        XCTAssertTrue(v.contains("brg") && v.contains("° T"), "expected bearing tail in: \(v)")
        // Parse the numeric NM value out of the line and bound-check.
        if let nm = Double(v.split(separator: " ").first ?? "0") {
            XCTAssertGreaterThan(nm, 25, "EDDM-EDMA should be > 25 NM, got \(nm)")
            XCTAssertLessThan(nm, 45, "EDDM-EDMA should be < 45 NM, got \(nm)")
        }
    }

    func test_distance_in_km() throws {
        let engine = try NumiEngine()
        let r = engine.evaluate("distance EDDM to EDMA in km")
        let v = r[0].value ?? ""
        XCTAssertTrue(v.contains("km"), "expected km in: \(v)")
        // ~65 km between Munich and Augsburg.
        if let km = Double(v.split(separator: " ").first ?? "0") {
            XCTAssertGreaterThan(km, 50)
            XCTAssertLessThan(km, 80)
        }
    }

    func test_distance_in_miles() throws {
        let engine = try NumiEngine()
        let r = engine.evaluate("distance EDDM to EDMA in mi")
        XCTAssertTrue((r[0].value ?? "").contains("mi"))
    }

    func test_distance_unknownAirport() throws {
        let engine = try NumiEngine()
        let r = engine.evaluate("distance EDDM to ZZZZ")
        XCTAssertTrue((r[0].value ?? "").contains("no coordinates"))
    }

    func test_distance_synonym_dist() throws {
        let engine = try NumiEngine()
        let r = engine.evaluate("dist KSFO to KLAX")
        let v = r[0].value ?? ""
        XCTAssertTrue(v.contains("NM"))
        // KSFO ↔ KLAX is roughly 293 NM.
        if let nm = Double(v.split(separator: " ").first ?? "0") {
            XCTAssertGreaterThan(nm, 280)
            XCTAssertLessThan(nm, 310)
        }
    }

    // MARK: - Sun events

    func test_sun_EDDM_basicShape() throws {
        let engine = try NumiEngine()
        let r = engine.evaluate("sun EDDM")
        XCTAssertEqual(r.count, 1)
        let v = r[0].value ?? ""
        XCTAssertTrue(v.contains("SR"), "expected SR label in: \(v)")
        XCTAssertTrue(v.contains("SS"), "expected SS label in: \(v)")
        XCTAssertTrue(v.contains("CT-end"), "expected CT-end label in: \(v)")
        XCTAssertTrue(v.contains("Z"), "expected Zulu marker in: \(v)")
    }

    func test_sun_unknownIcao_message() throws {
        let engine = try NumiEngine()
        let r = engine.evaluate("sun EDDM ZZZZ")
        XCTAssertTrue((r[0].value ?? "").contains("ZZZZ: no coordinates"))
    }

    // MARK: - Sun by place name

    func test_sunSummary_munich_daytime_countsDownToSunset() {
        let tz = TimeZone(identifier: "Europe/Berlin")!
        // 2026-06-21 12:00 local — sunrise ≈ 05:12, sunset ≈ 21:17.
        let now = ISO8601DateFormatter().date(from: "2026-06-21T10:00:00Z")!
        let v = NumiEngine.sunSummary(latitude: 48.137, longitude: 11.575,
                                      timeZone: tz, name: "Munich", now: now)
        XCTAssertTrue(v.hasPrefix("Sunrise 05:1"), v)
        XCTAssertTrue(v.contains("Sunset 21:1"), v)
        XCTAssertTrue(v.contains("sets in 9h"), v)
        XCTAssertTrue(v.hasSuffix("(Munich)"), v)
    }

    func test_sunSummary_afterDark_countsDownToTomorrowsSunrise() {
        let tz = TimeZone(identifier: "Asia/Makassar")!   // Bali, UTC+8
        // 2026-10-06 22:00 local.
        let now = ISO8601DateFormatter().date(from: "2026-10-06T14:00:00Z")!
        let v = NumiEngine.sunSummary(latitude: -8.65, longitude: 115.13,
                                      timeZone: tz, name: "Canggu", now: now)
        XCTAssertTrue(v.contains("Sunrise 06:0"), v)
        XCTAssertTrue(v.contains("Sunset 18:"), v)
        XCTAssertTrue(v.contains("rises in 8h"), v)
    }

    func test_sunPlace_dispatch() throws {
        let engine = try NumiEngine()
        let r = engine.evaluate("sun Munich\nMunich sun\nsun EDDM\nit is sun")
        XCTAssertNotNil(r[0].value)
        XCTAssertFalse((r[0].value ?? "").contains("no coordinates"), r[0].value ?? "")
        XCTAssertNotNil(r[1].value)
        XCTAssertTrue((r[2].value ?? "").contains("CT-end"))           // airport path unchanged
        XCTAssertFalse((r[3].value ?? "").contains("Resolving"))       // no geocoding for prose
    }

    func test_sun_multipleStations() throws {
        let engine = try NumiEngine()
        let r = engine.evaluate("sun EDDM EDMA")
        let v = r[0].value ?? ""
        let lines = v.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2, "expected one row per ICAO, got: \(v)")
        XCTAssertTrue(v.contains("EDDM"))
        XCTAssertTrue(v.contains("EDMA"))
    }

    // MARK: - Show the user what real output looks like

    func test_print_distance_and_sun_for_user() throws {
        let engine = try NumiEngine()
        let cases = [
            "distance EDDM to EDMA",
            "distance EDDM to EDMA in km",
            "dist KSFO to KLAX",
            "sun EDDM",
            "sun EDDM EDMA",
        ]
        print("=== TALLY DIST/SUN OUTPUT ===")
        for input in cases {
            let r = engine.evaluate(input)
            print("> \(input)")
            print(r.first?.value ?? "(nil)")
            print("")
        }
        print("=============================")
    }
}
