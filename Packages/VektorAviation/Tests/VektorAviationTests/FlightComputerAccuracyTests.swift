import XCTest
@testable import VektorAviation

/// Regression tests from the accuracy audit of the E6B tab. Expected values are computed independently of the code under test.
final class FlightComputerAccuracyTests: XCTestCase {

    // MARK: - Wind triangle

    func testWindTriangleMatchesIndependentVectorSolution() {
        // Reference values from a brute-force vector solver (heading swept in
        // 0.0001° steps until TAS-vector + wind-vector tracks the course).
        let cases: [(c: Double, tas: Double, wf: Double, ws: Double, hdg: Double, gs: Double)] = [
            (52, 120, 280, 15, 46.67, 129.52),
            (270, 120, 320, 25, 279.18, 102.39),
            (90, 100, 45, 40, 73.57, 67.63),
            (180, 90, 350, 30, 183.32, 119.39),
        ]
        for k in cases {
            let s = E6B.windTriangle(courseDeg: k.c, tas: k.tas, windFromDeg: k.wf, windSpeed: k.ws)
            XCTAssertEqual(s.headingDeg, k.hdg, accuracy: 0.01)
            XCTAssertEqual(s.groundSpeed, k.gs, accuracy: 0.01)
            XCTAssertTrue(s.isSolvable)
        }
    }

    func testWindTriangleFlagsCrosswindStrongerThanTAS() {
        // 90° crosswind of 60 kt at 50 KTAS: no heading holds the course.
        let s = E6B.windTriangle(courseDeg: 0, tas: 50, windFromDeg: 90, windSpeed: 60)
        XCTAssertFalse(s.isSolvable)
    }

    func testWindTriangleFlagsHeadwindStrongerThanTAS() {
        let s = E6B.windTriangle(courseDeg: 0, tas: 50, windFromDeg: 0, windSpeed: 60)
        XCTAssertFalse(s.isSolvable)
    }

    func testWindTriangleZeroTASUnsolvable() {
        XCTAssertFalse(E6B.windTriangle(courseDeg: 0, tas: 0, windFromDeg: 90, windSpeed: 10).isSolvable)
    }

    // MARK: - Runway heading input

    func testRunwayOrExactHeadingParsing() {
        XCTAssertEqual(Runway.heading(fromRunwayOrHeading: "27L"), 270)
        XCTAssertEqual(Runway.heading(fromRunwayOrHeading: "273"), 273)
        XCTAssertEqual(Runway.heading(fromRunwayOrHeading: "09"), 90)
        XCTAssertNil(Runway.heading(fromRunwayOrHeading: "361"))
        XCTAssertNil(Runway.heading(fromRunwayOrHeading: "37"))
    }

    // MARK: - True altitude

    func testTrueAltitudeSeaLevelStationRatioForm() {
        // IA 5000, 29.92, OAT +25 → ISA +5 at PA 5000 → ratio 298.15/278.15.
        let ta = Atmosphere.trueAltitudeFt(indicatedAltitudeFt: 5000, altimeterInHg: 29.92, oatC: 25)
        XCTAssertEqual(ta, 5000 * 298.15 / 278.15, accuracy: 0.01)
    }

    func testTrueAltitudeCorrectionOnlyAppliesAboveStation() {
        // At the station itself the altimeter reads true, whatever the temperature.
        let atField = Atmosphere.trueAltitudeFt(indicatedAltitudeFt: 6000, altimeterInHg: 30.10,
                                                oatC: -30, stationElevationFt: 6000)
        XCTAssertEqual(atField, 6000, accuracy: 0.001)

        // 2000 ft above a 6000 ft station in ISA −20: correction scales with
        // the 2000 ft column, not the full 8000 ft.
        let ta = Atmosphere.trueAltitudeFt(indicatedAltitudeFt: 8000, altimeterInHg: 29.92,
                                           oatC: -21, stationElevationFt: 6000)
        let expected = 6000 + 2000 * (252.15 / 272.15)
        XCTAssertEqual(ta, expected, accuracy: 0.01)
    }

    func testTrueAltitudeRuleOfThumbUsesHeightAboveStation() {
        let corr = Atmosphere.trueAltitudeCorrectionFt(indicatedAltitudeFt: 8000, altimeterInHg: 29.92,
                                                       oatC: -21, stationElevationFt: 6000)
        XCTAssertEqual(corr, 4 * -20 * 2, accuracy: 0.001)
    }
}
