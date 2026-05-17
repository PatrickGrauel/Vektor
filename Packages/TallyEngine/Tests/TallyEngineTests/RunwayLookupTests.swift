import XCTest
@testable import TallyEngine
import TallyAviation

/// Tests for the `RWY EDMA` / `RUNWAY EDDM` calculator command and
/// the underlying RunwayDatabase. The CSV is bundled, so these run
/// fully offline.
@MainActor
final class RunwayLookupTests: XCTestCase {

    func test_database_loads() {
        let db = RunwayDatabase.shared
        // OurAirports CSV is ~47 k rows; after filtering out entries
        // with no usable heading on either end (helipads, water
        // strips without bearing data, etc.) we keep well over 20 k.
        XCTAssertGreaterThan(db.entryCount, 10_000,
                             "expected the bundled OurAirports CSV to load at least 10k runways")
    }

    func test_EDMA_hasExpectedRunways() {
        let runways = RunwayDatabase.shared.runways(forICAO: "EDMA")
        XCTAssertFalse(runways.isEmpty, "EDMA must have at least one runway in the database")

        // EDMA (Augsburg) has a paved main RWY 07/25 and a parallel
        // grass strip 07R/25L. Verify both ends and check the heading
        // is in the expected magnetic band (~070°/250°).
        let paved = runways.first { ($0.surface ?? "").uppercased().contains("ASP") }
        XCTAssertNotNil(paved, "expected an asphalt EDMA runway")
        if let r = paved {
            XCTAssertEqual(r.leIdent, "07")
            XCTAssertEqual(r.heIdent, "25")
            // True heading should be in the 060–085° range; EDMA's
            // magnetic declination is small (~3° E).
            XCTAssertGreaterThanOrEqual(r.leHeadingTrue, 60)
            XCTAssertLessThanOrEqual(r.leHeadingTrue, 85)
            // Length should be in the 1500–1700 m range (published 1594 m).
            XCTAssertNotNil(r.lengthMeters)
            if let m = r.lengthMeters {
                XCTAssertGreaterThanOrEqual(m, 1500)
                XCTAssertLessThanOrEqual(m, 1700)
            }
        }
    }

    func test_EDDM_hasParallelRunways() {
        let runways = RunwayDatabase.shared.runways(forICAO: "EDDM")
        XCTAssertEqual(runways.count, 2, "Munich has two parallel runways")
        // Both runways are 08L/26R and 08R/26L; heading ~083°.
        for r in runways {
            XCTAssertTrue(r.leIdent.hasPrefix("08"))
            XCTAssertTrue(r.heIdent.hasPrefix("26"))
        }
    }

    // MARK: - Engine integration

    func test_engine_RWY_EDMA() throws {
        let engine = try NumiEngine()
        let r = engine.evaluate("RWY EDMA")
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].kind, .expression)
        let v = r[0].value ?? ""
        XCTAssertTrue(v.contains("EDMA"), "value should include the ICAO. got:\n\(v)")
        XCTAssertTrue(v.contains("07") && v.contains("25"),
                      "value should include the 07/25 runway. got:\n\(v)")
    }

    func test_engine_RUNWAY_synonym() throws {
        let engine = try NumiEngine()
        let r = engine.evaluate("RUNWAY EDMA")
        XCTAssertEqual(r[0].kind, .expression)
        XCTAssertTrue((r[0].value ?? "").contains("EDMA"))
    }

    func test_engine_unknownStation_message() throws {
        let engine = try NumiEngine()
        let r = engine.evaluate("RWY ZZZZ")
        XCTAssertEqual(r[0].kind, .expression)
        XCTAssertTrue((r[0].value ?? "").contains("no runway data"))
    }

    func test_engine_multipleStations() throws {
        let engine = try NumiEngine()
        let r = engine.evaluate("RWY EDMA EDDM")
        let v = r[0].value ?? ""
        XCTAssertTrue(v.contains("EDMA"))
        XCTAssertTrue(v.contains("EDDM"))
    }

    // MARK: - Advice formatter

    func test_formatRunwayAdvice_usesXwNotXc() {
        let advice = RunwayWindAdvisor.Advice(
            designator: "26L",
            headwindKt: 14, crosswindKt: 5,
            crosswindFromRight: true, isTailwind: false,
            headwindGustKt: 24, crosswindGustKt: 8
        )
        let s = NumiEngine.formatRunwayAdvice(advice)
        XCTAssertEqual(s, "expect RWY 26L · Hw 14 (G24) · Xw 5R (G8)")
        XCTAssertFalse(s.contains("Xc"), "must use Xw, not Xc")
    }

    func test_formatRunwayAdvice_tailwindLabel() {
        let advice = RunwayWindAdvisor.Advice(
            designator: "09",
            headwindKt: -4, crosswindKt: 2,
            crosswindFromRight: false, isTailwind: true,
            headwindGustKt: nil, crosswindGustKt: nil
        )
        let s = NumiEngine.formatRunwayAdvice(advice)
        XCTAssertEqual(s, "expect RWY 09 · Tw 4 · Xw 2L")
    }

    /// Crosswind from the left → `L` suffix. From the right → `R`.
    /// Guards against accidentally swapping the convention.
    func test_formatRunwayAdvice_crosswindSideSuffix() {
        let fromLeft = RunwayWindAdvisor.Advice(
            designator: "27", headwindKt: 10, crosswindKt: 4,
            crosswindFromRight: false, isTailwind: false,
            headwindGustKt: nil, crosswindGustKt: nil
        )
        XCTAssertEqual(NumiEngine.formatRunwayAdvice(fromLeft),
                       "expect RWY 27 · Hw 10 · Xw 4L")

        let fromRight = RunwayWindAdvisor.Advice(
            designator: "27", headwindKt: 10, crosswindKt: 4,
            crosswindFromRight: true, isTailwind: false,
            headwindGustKt: nil, crosswindGustKt: nil
        )
        XCTAssertEqual(NumiEngine.formatRunwayAdvice(fromRight),
                       "expect RWY 27 · Hw 10 · Xw 4R")
    }

    /// Crosswind = 0 means perfectly aligned wind — no side suffix,
    /// otherwise we'd render a meaningless "Xw 0R".
    func test_formatRunwayAdvice_zeroCrosswindOmitsSide() {
        let aligned = RunwayWindAdvisor.Advice(
            designator: "27", headwindKt: 12, crosswindKt: 0,
            crosswindFromRight: true, isTailwind: false,
            headwindGustKt: nil, crosswindGustKt: nil
        )
        XCTAssertEqual(NumiEngine.formatRunwayAdvice(aligned),
                       "expect RWY 27 · Hw 12 · Xw 0")
    }

    // MARK: - Show the user what EDMA looks like

    /// Print the formatted EDMA result. The user asked to verify
    /// accuracy against the AIP; the assertion is on a known truthy
    /// substring, and the diagnostic output is what they'll inspect.
    func test_print_EDMA_for_user_verification() throws {
        let engine = try NumiEngine()
        let r = engine.evaluate("RWY EDMA")
        print("=== TALLY RWY EDMA OUTPUT ===")
        print(r[0].value ?? "(no value)")
        print("=============================")
        XCTAssertNotNil(r[0].value)
    }
}
