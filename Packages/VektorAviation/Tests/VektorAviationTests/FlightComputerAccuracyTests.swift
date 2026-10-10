import XCTest
@testable import VektorAviation

/// Regression tests from the accuracy audit of the E6B and Weight & Balance
/// tabs. Expected values are computed independently of the code under test.
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

    // MARK: - Envelope boundaries (limits are inclusive)

    private let sloped = WeightBalance.Envelope(vertices: [
        (35.0, 1500), (35.0, 1950), (41.0, 2550), (47.3, 2550), (47.3, 1500),
    ])

    func testEnvelopeBoundariesAreInclusive() {
        XCTAssertTrue(sloped.contains(cg: 44, weight: 2550), "exactly at max weight")
        XCTAssertTrue(sloped.contains(cg: 47.3, weight: 2000), "exactly at aft limit")
        XCTAssertTrue(sloped.contains(cg: 35.0, weight: 1700), "exactly at forward limit")
        XCTAssertTrue(sloped.contains(cg: 38.0, weight: 2250), "exactly on sloped forward limit")
        XCTAssertTrue(sloped.contains(cg: 41.0, weight: 2550), "on a vertex")
    }

    func testSlopedForwardLimitRejectsLoadingABoxWouldAccept() {
        // At 2550 lb the forward limit is 41.0 in. A 35.0–47.3 box would pass 36 in.
        XCTAssertFalse(sloped.contains(cg: 36.0, weight: 2550))
        XCTAssertFalse(sloped.contains(cg: 38.0, weight: 2300)) // fwd limit there is 38.5
        XCTAssertTrue(sloped.contains(cg: 38.6, weight: 2300))
    }

    func testEnvelopeOutsideJustPastLimits() {
        XCTAssertFalse(sloped.contains(cg: 47.31, weight: 2000))
        XCTAssertFalse(sloped.contains(cg: 44, weight: 2550.1))
        XCTAssertFalse(sloped.contains(cg: 34.99, weight: 1700))
    }

    func testDegenerateEnvelopeIsInvalidAndNeverContains() {
        let line = WeightBalance.Envelope(vertices: [(35, 1500), (40, 2000), (45, 2500)])
        XCTAssertFalse(line.isValid)
        XCTAssertFalse(line.contains(cg: 40, weight: 2000))
        XCTAssertFalse(WeightBalance.Envelope(vertices: []).isValid)
    }

    func testSimpleBoxDetection() {
        XCTAssertFalse(sloped.isSimpleBox)
        let box = WeightBalance.Envelope(vertices: [(35, 0), (47.3, 0), (47.3, 2300), (35, 2300)])
        XCTAssertTrue(box.isSimpleBox)
    }

    // MARK: - Loading conditions

    private func profile(fuel: Double, burn: Double, baggage: Double = 30) -> WBProfile {
        WBProfile(
            name: "t",
            stations: [
                .init(name: "Empty", weight: 1500, arm: 39),
                .init(name: "Front", weight: 340, arm: 37),
                .init(name: "Fuel", weight: fuel, arm: 48, isFuel: true),
                .init(name: "Baggage", weight: baggage, arm: 95, maxWeight: 120),
            ],
            envelope: [
                .init(cg: 35.0, weight: 1500), .init(cg: 35.0, weight: 1950),
                .init(cg: 41.0, weight: 2550), .init(cg: 47.3, weight: 2550),
                .init(cg: 47.3, weight: 1500),
            ],
            fuelBurn: burn
        )
    }

    func testTakeoffLandingZeroFuelConditions() {
        let e = profile(fuel: 240, burn: 60).evaluate()
        XCTAssertEqual(e.conditions.map(\.kind), [.takeoff, .landing, .zeroFuel])

        let to = e.conditions[0].result
        XCTAssertEqual(to.totalWeight, 2110, accuracy: 1e-9)
        let toMoment: Double = 1500*39 + 340*37 + 240*48 + 30*95
        XCTAssertEqual(to.cg, toMoment / 2110, accuracy: 1e-9)

        let ldg = e.conditions[1].result
        XCTAssertEqual(ldg.totalWeight, 2050, accuracy: 1e-9)
        let ldgMoment: Double = 1500*39 + 340*37 + 180*48 + 30*95
        XCTAssertEqual(ldg.cg, ldgMoment / 2050, accuracy: 1e-9)

        let zf = e.conditions[2].result
        XCTAssertEqual(zf.totalWeight, 1870, accuracy: 1e-9)
        let zfMoment: Double = 1500*39 + 340*37 + 30*95
        XCTAssertEqual(zf.cg, zfMoment / 1870, accuracy: 1e-9)
        XCTAssertTrue(e.isWithinLimits)
    }

    func testLandingConditionCanFailWhenTakeoffPasses() {
        // Heavy aft baggage + fuel forward of it: takeoff OK, CG moves aft as fuel burns.
        let p = WBProfile(
            name: "t",
            stations: [
                .init(name: "Empty", weight: 1000, arm: 40),
                .init(name: "Fuel", weight: 600, arm: 30, isFuel: true),
                .init(name: "Aft cargo", weight: 200, arm: 80),
            ],
            envelope: [.init(cg: 30, weight: 800), .init(cg: 45, weight: 800),
                       .init(cg: 45, weight: 2000), .init(cg: 30, weight: 2000)],
            fuelBurn: 500
        )
        let e = p.evaluate()
        XCTAssertEqual(e.conditions[0].result.inEnvelope, true)   // 40.0 in
        XCTAssertEqual(e.conditions[1].result.inEnvelope, false)  // 45.38 in
        XCTAssertFalse(e.isWithinLimits)
    }

    func testStationOverLimitFailsOverallVerdict() {
        let e = profile(fuel: 240, burn: 60, baggage: 150).evaluate()
        XCTAssertEqual(e.overLimitStations, ["Baggage"])
        XCTAssertFalse(e.isWithinLimits)
    }

    func testBurnMoreThanFuelOnBoardFails() {
        let e = profile(fuel: 100, burn: 120).evaluate()
        XCTAssertTrue(e.fuelBurnExceedsFuel)
        XCTAssertFalse(e.isWithinLimits)
    }

    func testNegativeStationWeightFails() {
        var p = profile(fuel: 240, burn: 60)
        p.stations[1].weight = -10
        XCTAssertFalse(p.evaluate().isWithinLimits)
    }

    func testEmptyEnvelopeNeverPasses() {
        var p = profile(fuel: 240, burn: 60)
        p.envelope = []
        XCTAssertFalse(p.evaluate().isWithinLimits)
    }

    func testExampleProfileIsSelfConsistent() {
        XCTAssertTrue(WBProfile.example.evaluate().isWithinLimits)
        XCTAssertFalse(WBProfile.example.weightBalance.envelope!.isSimpleBox)
        XCTAssertFalse(WBProfile.blank.evaluate().isWithinLimits)
    }

    // MARK: - Persistence migration

    func testLegacyBoxProfileDecodes() throws {
        let json = """
        {"id":"7E1C2A6E-7B53-4C35-9C07-6C3B7A8C1F00","name":"My 172",
         "stations":[{"id":"7E1C2A6E-7B53-4C35-9C07-6C3B7A8C1F01","name":"Empty","weight":1500,"arm":39},
                     {"id":"7E1C2A6E-7B53-4C35-9C07-6C3B7A8C1F02","name":"Fuel (40 gal)","weight":240,"arm":48}],
         "envelope":{"minCG":35,"maxCG":47.3,"maxWeight":2300}}
        """
        let p = try JSONDecoder().decode(WBProfile.self, from: Data(json.utf8))
        XCTAssertEqual(p.envelope.count, 4)
        XCTAssertEqual(p.envelope.map(\.weight).max(), 2300)
        XCTAssertFalse(p.stations[0].isFuel)
        XCTAssertTrue(p.stations[1].isFuel)
        XCTAssertTrue(p.weightBalance.envelope!.isSimpleBox)

        let round = try JSONDecoder().decode(WBProfile.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(round, p)
    }
}
