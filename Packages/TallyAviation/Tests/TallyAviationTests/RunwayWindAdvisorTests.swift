import XCTest
@testable import TallyAviation

/// Verifies the wind-based runway-in-use suggestion logic.
final class RunwayWindAdvisorTests: XCTestCase {

    /// Build a synthetic Munich runway list for tests so we don't
    /// depend on RunwayDatabase having a particular EDDM record.
    /// EDDM real-world: 08L/26R and 08R/26L, true heading 83.4°.
    private var eddmRunways: [RunwayInfo] {
        let leftPair = RunwayInfo(
            leIdent: "08L", leHeadingTrue: 83.4,
            leLatitude: nil, leLongitude: nil, leElevationFt: nil,
            heIdent: "26R", heHeadingTrue: 263.4,
            heLatitude: nil, heLongitude: nil, heElevationFt: nil,
            lengthFt: 13123, widthFt: 197, surface: "CON",
            lighted: true, closed: false
        )
        let rightPair = RunwayInfo(
            leIdent: "08R", leHeadingTrue: 83.4,
            leLatitude: nil, leLongitude: nil, leElevationFt: nil,
            heIdent: "26L", heHeadingTrue: 263.4,
            heLatitude: nil, heLongitude: nil, heElevationFt: nil,
            lengthFt: 13123, widthFt: 197, surface: "CON",
            lighted: true, closed: false
        )
        return [leftPair, rightPair]
    }

    private func metar(wind: String) -> DecodedMetar {
        // Minimal METAR text — the parser only needs the wind group.
        let raw = "METAR EDDM 141150Z \(wind) CAVOK 12/02 Q1004 NOSIG"
        return MetarParser.parse(raw)
    }

    // MARK: - Headwind from the west → 26L/R wins

    func test_westWind_picks26end() {
        let advice = RunwayWindAdvisor.advise(metar: metar(wind: "28010KT"),
                                              runways: eddmRunways)
        XCTAssertNotNil(advice)
        XCTAssertTrue(advice?.designator.hasPrefix("26") ?? false,
                      "expected a 26-end, got: \(advice?.designator ?? "nil")")
        XCTAssertFalse(advice?.isTailwind ?? true)
        // Wind 280° vs runway 263.4°: ~17° offset → mostly headwind.
        // cos(17°) ≈ 0.956 → headwind ~ 9.56 → rounds to 10.
        XCTAssertGreaterThanOrEqual(advice?.headwindKt ?? 0, 9)
    }

    // MARK: - Headwind from the east → 08L/R wins

    func test_eastWind_picks08end() {
        let advice = RunwayWindAdvisor.advise(metar: metar(wind: "09010KT"),
                                              runways: eddmRunways)
        XCTAssertNotNil(advice)
        XCTAssertTrue(advice?.designator.hasPrefix("08") ?? false)
    }

    // MARK: - Calm wind → no advice

    func test_calmWind_noAdvice() {
        let advice = RunwayWindAdvisor.advise(metar: metar(wind: "00000KT"),
                                              runways: eddmRunways)
        XCTAssertNil(advice)
    }

    // MARK: - Gusts produce gust components

    func test_gustComponents_included() {
        let advice = RunwayWindAdvisor.advise(metar: metar(wind: "28015G25KT"),
                                              runways: eddmRunways)
        XCTAssertNotNil(advice)
        XCTAssertNotNil(advice?.headwindGustKt)
        // Gust headwind = 25 × cos(17°) ≈ 24
        if let g = advice?.headwindGustKt {
            XCTAssertEqual(g, 24, accuracy: 1)
        }
    }

    // MARK: - Pure crosswind (north wind on east-west runway)

    func test_crosswindOnly_classifiedCorrectly() {
        let advice = RunwayWindAdvisor.advise(metar: metar(wind: "18010KT"),
                                              runways: eddmRunways)
        XCTAssertNotNil(advice)
        // North or south wind on E/W runway: nearly all crosswind, no
        // headwind. Picked end has near-zero headwind magnitude.
        let head = abs(advice?.headwindKt ?? 999)
        XCTAssertLessThanOrEqual(head, 2)
        XCTAssertGreaterThanOrEqual(advice?.crosswindKt ?? 0, 8)
    }

    // MARK: - Tailwind-everywhere edge case

    func test_singleRunway_tailwindFallback() {
        // Build a single one-way runway (heHeadingTrue NaN — closed end).
        let oneWay = RunwayInfo(
            leIdent: "27", leHeadingTrue: 270,
            leLatitude: nil, leLongitude: nil, leElevationFt: nil,
            heIdent: "09", heHeadingTrue: .nan,
            heLatitude: nil, heLongitude: nil, heElevationFt: nil,
            lengthFt: 5000, widthFt: 100, surface: "ASP",
            lighted: true, closed: false
        )
        // Wind from 090° on a 270° runway → pure tailwind.
        let advice = RunwayWindAdvisor.advise(metar: metar(wind: "09010KT"),
                                              runways: [oneWay])
        XCTAssertNotNil(advice)
        XCTAssertTrue(advice?.isTailwind ?? false)
        XCTAssertEqual(advice?.designator, "27")
    }

    // MARK: - Closed runways are skipped

    func test_closedRunways_skipped() {
        let closed = RunwayInfo(
            leIdent: "27", leHeadingTrue: 270,
            leLatitude: nil, leLongitude: nil, leElevationFt: nil,
            heIdent: "09", heHeadingTrue: 90,
            heLatitude: nil, heLongitude: nil, heElevationFt: nil,
            lengthFt: 5000, widthFt: 100, surface: "ASP",
            lighted: true, closed: true
        )
        let advice = RunwayWindAdvisor.advise(metar: metar(wind: "27010KT"),
                                              runways: [closed])
        XCTAssertNil(advice, "closed runways must not be recommended")
    }
}

// MARK: - Test-only RunwayInfo synthesis helper
//
// `RunwayInfo`'s memberwise initializer is `internal` because the type
// is `public`. With `@testable import TallyAviation`, the tests can
// see the initializer directly — but the test list above relies on
// explicit-parameter construction, so this extension is unnecessary.
