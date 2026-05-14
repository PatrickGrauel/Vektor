import XCTest
@testable import TallyEngine
import TallyAviation

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
        let r = engine.evaluate("sun ZZZZ")
        XCTAssertTrue((r[0].value ?? "").contains("no coordinates"))
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
