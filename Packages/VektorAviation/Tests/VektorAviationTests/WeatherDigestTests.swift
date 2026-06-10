import XCTest
@testable import VektorAviation

/// Exercises the METAR/TAF → plain-language flattening. We feed real raw
/// reports through the public parsers and derive `now` from the parsed TAF
/// validity window, so the assertions are deterministic regardless of the
/// real wall-clock date (the parser anchors Zulu day/hour to "today").
final class WeatherDigestTests: XCTestCase {

    private let berlin = TimeZone(identifier: "Europe/Berlin")!

    /// Munich: partly cloudy now, a BECMG wind shift, a TEMPO thundery
    /// shower window, then FM clearing to CAVOK.
    func testMunichOutlook() {
        let metar = MetarParser.parse("EDDM 121150Z 24008KT 9999 SCT035 18/12 Q1018")
        let taf = TafParser.parse(
            "TAF EDDM 121100Z 1212/1318 24008KT 9999 SCT035 " +
            "BECMG 1214/1216 27012KT " +
            "TEMPO 1216/1220 4000 SHRA SCT025CB " +
            "FM131000 28006KT CAVOK")

        // 1 hour into the TAF's prevailing window.
        let now = taf.validityStart!.addingTimeInterval(3600)
        let d = WeatherDigest.make(place: "Munich (EDDM)", metar: metar, taf: taf,
                                   timeZone: berlin, now: now)

        print("=== MUNICH ===\n\(d.place)\nnow \(d.nowEmoji) \(d.nowLine)")
        print("outlook:\n" + d.outlook.map { "  • \($0)" }.joined(separator: "\n"))
        print("hours: " + d.hours.map { "\($0.emoji)\($0.label)\($0.isChance ? "?" : "")" }.joined(separator: " "))

        // "Now" carries temperature + a plain condition.
        XCTAssertTrue(d.nowLine.contains("18°C"), d.nowLine)
        XCTAssertTrue(d.nowLine.contains("partly cloudy"), d.nowLine)
        XCTAssertFalse(d.nowLine.contains("SCT"), "raw codes leaked: \(d.nowLine)")

        // The TEMPO thundery-shower window should surface as an evening caveat.
        let joined = d.outlook.joined(separator: " | ")
        XCTAssertTrue(d.hasForecast)
        XCTAssertTrue(joined.lowercased().contains("evening"), joined)
        XCTAssertTrue(joined.contains("chance of"), joined)
        XCTAssertTrue(joined.contains("storms") || joined.contains("showers"), joined)
        // No aviation grammar should ever leak into the prose.
        for token in ["BECMG", "TEMPO", "PROB", "FM13", "CAVOK", "1212/1318", "SCT", "KT"] {
            XCTAssertFalse(joined.contains(token), "leaked \(token): \(joined)")
        }
        XCTAssertFalse(d.hours.isEmpty)
    }

    /// Calm and clear all the way through → a single reassuring line, no
    /// invented events.
    func testClearStaysClear() {
        let metar = MetarParser.parse("LOWW 121150Z 28005KT CAVOK 22/10 Q1020")
        let taf = TafParser.parse("TAF LOWW 121100Z 1212/1318 28006KT CAVOK")
        let now = taf.validityStart!.addingTimeInterval(3600)
        let d = WeatherDigest.make(place: "Vienna (LOWW)", metar: metar, taf: taf,
                                   timeZone: berlin, now: now)
        print("=== VIENNA ===\nnow \(d.nowEmoji) \(d.nowLine)\noutlook: \(d.outlook)")

        XCTAssertTrue(d.nowLine.contains("22°C"), d.nowLine)
        XCTAssertTrue(d.nowLine.contains("clear"), d.nowLine)
        XCTAssertEqual(d.outlook.count, 1)
        XCTAssertTrue(d.outlook[0].lowercased().contains("clear"), d.outlook[0])
    }

    /// No TAF available → still get "now" from the METAR, but no forecast.
    func testNoTaf() {
        let metar = MetarParser.parse("EDDM 121150Z VRB03KT 9999 BKN012 09/08 Q1012")
        let d = WeatherDigest.make(place: "Munich (EDDM)", metar: metar, taf: nil,
                                   timeZone: berlin, now: metar.observedAt ?? Date())
        XCTAssertFalse(d.hasForecast)
        XCTAssertTrue(d.nowLine.contains("9°C"), d.nowLine)
        XCTAssertTrue(d.nowLine.contains("cloudy"), d.nowLine)   // BKN → cloudy
        XCTAssertTrue(d.hours.isEmpty)
        XCTAssertTrue(d.outlook.isEmpty)
    }

    func testCompassAndWind() {
        XCTAssertEqual(WeatherDigest.compass(0), "N")
        XCTAssertEqual(WeatherDigest.compass(270), "W")
        XCTAssertEqual(WeatherDigest.compass(45), "NE")
        // 8 kt ≈ 15 km/h, from 240° → "W"-ish (SW actually 240 → SW).
        let w = DecodedMetar.Wind(fromDeg: 240, isVariable: false, speedKt: 8, gustKt: nil, variableRange: nil)
        XCTAssertEqual(WeatherDigest.windText(w), "wind 15 km/h SW")
    }

    /// Outlook times must be in the airport's local zone, not Zulu. A change
    /// at 09:00 UTC is 18:00 JST — "this evening". If the UTC→local conversion
    /// were dropped it would read "this morning".
    func testTokyoUsesLocalJSTNotUTC() {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!   // UTC+9, no DST
        let metar = MetarParser.parse("RJTT 100600Z 36005KT CAVOK 24/12 Q1015")
        let taf = TafParser.parse("TAF RJTT 100500Z 1006/1112 36005KT 9999 FEW030 FM100900 09008KT BKN015")
        let now = taf.validityStart!.addingTimeInterval(3600)   // 07:00Z = 16:00 JST
        let d = WeatherDigest.make(place: "Tokyo (RJTT)", metar: metar, taf: taf,
                                   timeZone: tokyo, now: now)
        print("=== TOKYO ===\nnow \(d.nowLine)\noutlook: \(d.outlook)\nhours: \(d.hours.map { "\($0.emoji)\($0.label)" })")
        let joined = d.outlook.joined(separator: " | ").lowercased()
        XCTAssertTrue(joined.contains("evening"), "expected JST evening, got: \(joined)")
        XCTAssertFalse(joined.contains("morning"), "leaked UTC time-of-day: \(joined)")
    }
}
