import XCTest
@testable import TallyAviation

final class TallyAviationTests: XCTestCase {

    // MARK: Atmosphere

    func testISATempAt0FtIs15C() {
        XCTAssertEqual(Atmosphere.isaTempC(altitudeFt: 0), 15, accuracy: 0.0001)
    }

    func testISATempAt10000FtIs_minus5C() {
        XCTAssertEqual(Atmosphere.isaTempC(altitudeFt: 10_000), -5, accuracy: 0.001)
    }

    func testPressureAltitudeStandardSetting() {
        XCTAssertEqual(
            Atmosphere.pressureAltitudeFt(indicatedAltitudeFt: 5_000, altimeterInHg: 29.92),
            5_000, accuracy: 0.5
        )
    }

    func testPressureAltitudeLowQNH() {
        // 29.42 inHg → +500 ft pressure alt above indicated
        XCTAssertEqual(
            Atmosphere.pressureAltitudeFt(indicatedAltitudeFt: 5_000, altimeterInHg: 29.42),
            5_500, accuracy: 0.5
        )
    }

    func testDensityAltitudeHotDay() {
        // At sea level, 30°C, standard pressure: DA ≈ 1800 ft (FAA approximation)
        let da = Atmosphere.densityAltitudeFt(pressureAltitudeFt: 0, oatC: 30)
        XCTAssertEqual(da, 1800, accuracy: 1)
    }

    // MARK: E6B wind triangle

    func testDirectHeadwind() {
        // Course 360, TAS 100, wind 360@20 → headwind 20, GS 80, WCA 0
        let s = E6B.windTriangle(courseDeg: 360, tas: 100, windFromDeg: 360, windSpeed: 20)
        XCTAssertEqual(s.headwind, 20, accuracy: 0.001)
        XCTAssertEqual(s.crosswind, 0, accuracy: 0.001)
        XCTAssertEqual(s.groundSpeed, 80, accuracy: 0.001)
        XCTAssertEqual(s.wcaDeg, 0, accuracy: 0.001)
    }

    func testDirectTailwind() {
        let s = E6B.windTriangle(courseDeg: 0, tas: 100, windFromDeg: 180, windSpeed: 20)
        XCTAssertEqual(s.groundSpeed, 120, accuracy: 0.001)
        XCTAssertEqual(s.headwind, -20, accuracy: 0.001)
    }

    func testCrosswindOnly() {
        // Course 360, TAS 100, wind 090@20 → crosswind from right, WCA ~ +11.5°
        let s = E6B.windTriangle(courseDeg: 360, tas: 100, windFromDeg: 90, windSpeed: 20)
        XCTAssertEqual(s.crosswind, 20, accuracy: 0.001)
        XCTAssertEqual(s.headwind, 0, accuracy: 0.001)
        XCTAssertEqual(s.wcaDeg, asin(20.0/100.0) * 180.0 / .pi, accuracy: 0.001)
    }

    // MARK: Runway

    func testRunwayDirectHeadwind() {
        let c = Runway.components(runwayHeadingDeg: 270, windFromDeg: 270, windSpeed: 15)
        XCTAssertEqual(c.headwind, 15, accuracy: 0.001)
        XCTAssertEqual(c.crosswind, 0, accuracy: 0.001)
    }

    func testRunwayQuarteringRight() {
        // Runway 27 (270°), wind 300@10 → headwind ~8.66, crosswind ~5 from right
        let c = Runway.components(runwayHeadingDeg: 270, windFromDeg: 300, windSpeed: 10)
        XCTAssertEqual(c.headwind, 10 * cos(30 * .pi / 180), accuracy: 0.001)
        XCTAssertEqual(c.crosswind, 10 * sin(30 * .pi / 180), accuracy: 0.001)
        XCTAssertTrue(c.crosswindFromRight)
    }

    func testRunwayHeadingParsing() {
        XCTAssertEqual(Runway.headingFromRunwayId("27"), 270)
        XCTAssertEqual(Runway.headingFromRunwayId("27L"), 270)
        XCTAssertEqual(Runway.headingFromRunwayId("09R"), 90)
        XCTAssertNil(Runway.headingFromRunwayId("xx"))
    }

    // MARK: Fuel

    func testEndurance() {
        XCTAssertEqual(Fuel.enduranceHours(fuelQty: 50, burnRate: 10), 5, accuracy: 0.0001)
    }

    func testTOD() {
        // Lose 10,000 ft at 500 fpm, GS 120 kt → 20 min / 40 NM
        let d = Fuel.topOfDescentDistance(altitudeToLoseFt: 10_000, descentRateFpm: 500, groundSpeed: 120)
        XCTAssertEqual(d, 40, accuracy: 0.001)
    }

    // MARK: Weight & balance

    func testCGSimple() {
        let wb = WeightBalance(stations: [
            .init(name: "Empty",  weight: 1700, armIn: 32),
            .init(name: "Pilot",  weight: 170,  armIn: 37),
            .init(name: "Fuel",   weight: 240,  armIn: 48),
        ])
        let r = wb.compute()
        XCTAssertEqual(r.totalWeight, 2110, accuracy: 0.001)
        XCTAssertEqual(r.cg, (1700*32 + 170*37 + 240*48) / 2110, accuracy: 0.001)
    }

    func testEnvelopeInsideOutside() {
        let env = WeightBalance.Envelope(vertices: [
            (32, 1500), (40, 1500), (40, 2300), (32, 2300)
        ])
        XCTAssertTrue(env.contains(cg: 36, weight: 2000))
        XCTAssertFalse(env.contains(cg: 31, weight: 2000))
    }

    // MARK: METAR

    func testMetarKSFOExample() {
        let raw = "METAR KSFO 131056Z 28015G22KT 10SM FEW020 SCT250 16/12 A2998 RMK AO2"
        let m = MetarParser.parse(raw)
        XCTAssertEqual(m.station, "KSFO")
        XCTAssertEqual(m.wind?.fromDeg, 280)
        XCTAssertEqual(m.wind?.speedKt, 15)
        XCTAssertEqual(m.wind?.gustKt, 22)
        XCTAssertEqual(m.visibility?.statuteMiles, 10)
        XCTAssertEqual(m.clouds.count, 2)
        XCTAssertEqual(m.clouds.first?.altitudeFt, 2000)
        XCTAssertEqual(m.temperatureC, 16)
        XCTAssertEqual(m.dewpointC, 12)
        XCTAssertEqual(m.altimeter?.inHg ?? 0, 29.98, accuracy: 0.0001)
        XCTAssertEqual(m.remarks, "AO2")
    }

    func testMetarMetricEurope() {
        let raw = "EDDM 131050Z 24012KT 9999 FEW040 BKN090 18/10 Q1015"
        let m = MetarParser.parse(raw)
        XCTAssertEqual(m.station, "EDDM")
        XCTAssertEqual(m.wind?.fromDeg, 240)
        XCTAssertEqual(m.wind?.speedKt, 12)
        XCTAssertEqual(m.visibility?.meters, 9999)
        XCTAssertEqual(m.temperatureC, 18)
        XCTAssertEqual(m.dewpointC, 10)
        XCTAssertEqual(m.altimeter?.hPa, 1015)
    }

    func testMetarCAVOK() {
        let raw = "LIRF 131120Z 22008KT 180V250 CAVOK 22/14 Q1018"
        let m = MetarParser.parse(raw)
        XCTAssertEqual(m.visibility?.isCAVOK, true)
        XCTAssertEqual(m.wind?.variableRange?.0, 180)
        XCTAssertEqual(m.wind?.variableRange?.1, 250)
    }

    func testMetarNegativeTemp() {
        let raw = "CYUL 131200Z 32012KT 15SM SCT040 BKN200 M02/M08 A2992"
        let m = MetarParser.parse(raw)
        XCTAssertEqual(m.temperatureC, -2)
        XCTAssertEqual(m.dewpointC, -8)
    }

    // MARK: - TREND group (TEMPO / BECMG / NOSIG suffix on ICAO METARs)

    func testMetarWithTempoTrend() {
        // Real-world EDDM METAR with a TEMPO trend group at the end.
        let raw = "METAR EDDM 131050Z AUTO 25014KT 220V290 CAVOK 14/02 Q1007 TEMPO 25015G25KT"
        let m = MetarParser.parse(raw)
        XCTAssertEqual(m.station, "EDDM")
        XCTAssertEqual(m.wind?.fromDeg, 250)
        XCTAssertEqual(m.wind?.speedKt, 14)
        XCTAssertEqual(m.altimeter?.hPa, 1007)
        XCTAssertEqual(m.trend, "TEMPO 25015G25KT")
        // Trend must NOT pollute the main wind reading.
        XCTAssertEqual(m.wind?.gustKt, nil)
    }

    func testMetarWithNoSigTrend() {
        let raw = "EDDF 131020Z 27008KT CAVOK 12/04 Q1015 NOSIG"
        let m = MetarParser.parse(raw)
        XCTAssertEqual(m.trend, "NOSIG")
    }

    func testMetarWithoutTrendStillParses() {
        let raw = "KSFO 130256Z 28012KT 10SM FEW040 18/12 A2995"
        let m = MetarParser.parse(raw)
        XCTAssertNil(m.trend)
    }

    // MARK: - TAF parsing

    func testTafBasicStructure() {
        let raw = "TAF KSFO 130200Z 1302/1406 28006KT P6SM FEW008 OVC020 FM131800 27006KT P6SM SCT025 BKN200 FM140000 30006KT P6SM FEW015"
        let t = TafParser.parse(raw)
        XCTAssertEqual(t.station, "KSFO")
        XCTAssertNotNil(t.validityStart)
        XCTAssertNotNil(t.validityEnd)
        XCTAssertGreaterThanOrEqual(t.periods.count, 3) // main + 2 FM
        // First period (main / initial) should have a wind & cloud
        let main = t.periods.first!
        XCTAssertEqual(main.wind?.fromDeg, 280)
        XCTAssertEqual(main.wind?.speedKt, 6)
        XCTAssertFalse(main.clouds.isEmpty)
    }

    func testTafTempoAndProb() {
        let raw = "TAF EDDM 130500Z 1306/1412 27010KT 9999 BKN020 TEMPO 1306/1310 BKN012 PROB30 TEMPO 1310/1314 -RA BKN008"
        let t = TafParser.parse(raw)
        XCTAssertEqual(t.station, "EDDM")
        // Expect at least: main, TEMPO, PROB30 TEMPO
        let kinds = t.periods.map(\.kind)
        XCTAssertTrue(kinds.contains(.temporary))
        XCTAssertTrue(kinds.contains(.probability30))
    }

    func testTafAmdHandled() {
        let raw = "TAF AMD EGLL 131140Z 1312/1418 23015G27KT 9999 BKN025"
        let t = TafParser.parse(raw)
        XCTAssertEqual(t.station, "EGLL")
        XCTAssertEqual(t.periods.first?.wind?.speedKt, 15)
        XCTAssertEqual(t.periods.first?.wind?.gustKt, 27)
    }
}
