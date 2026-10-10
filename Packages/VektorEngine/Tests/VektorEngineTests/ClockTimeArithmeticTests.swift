import XCTest
@testable import VektorEngine

@MainActor
final class ClockTimeArithmeticTests: XCTestCase {
    func testReportedClockArithmetic() throws {
        let engine = try NumiEngine()
        let result = engine.evaluate("9pm + 33min").first
        XCTAssertEqual(result?.kind, .timezone)
        XCTAssertEqual(result?.value, "9:33 pm")
        XCTAssertNil(result?.hint)
    }

    func testPartialMinutesNeverProduceDistance() throws {
        let engine = try NumiEngine()
        for source in ["9pm +", "9pm + 33mi", "9pm + 33meters", "9pm * 2"] {
            let result = engine.evaluate(source).first
            XCTAssertEqual(result?.kind, .error, source)
            XCTAssertEqual(result?.hint, "Use hours, minutes or seconds with a clock time.", source)
            XCTAssertFalse(result?.value?.contains("km") ?? true, source)
        }
    }

    func testBareMeridiemIsClockWhileMilitaryNumbersRemainNumbers() throws {
        let engine = try NumiEngine()
        XCTAssertEqual(engine.evaluate("9pm").first?.value, "9:00 pm")
        XCTAssertEqual(engine.evaluate("9 PM").first?.value, "9:00 pm")
        XCTAssertEqual(engine.evaluate("1800 + 100").first?.value, "1 900")
        XCTAssertEqual(engine.evaluate("1800 + 100").first?.kind, .expression)
    }

    func testClockFormsAndChainedDurations() throws {
        let engine = try NumiEngine()
        let examples = [
            ("9 pm + 33 minutes", "9:33 pm"),
            ("9PM + 33MIN", "9:33 pm"),
            ("9.30pm + 33min", "10:03 pm"),
            ("21:00 + 33min", "21:33"),
            ("9pm + 1h - 27min", "9:33 pm"),
            ("9pm − 33min", "8:27 pm"),
            ("9pm + 33", "6:00 am (+2d)"),
        ]
        for (source, expected) in examples {
            let result = engine.evaluate(source).first
            XCTAssertEqual(result?.kind, .timezone, source)
            XCTAssertEqual(result?.value, expected, source)
        }
    }

    func testMidnightRolloverAndTwelveOClock() throws {
        let engine = try NumiEngine()
        let examples = [
            ("11:50pm + 20min", "12:10 am (+1d)"),
            ("12:10am - 20min", "11:50 pm (-1d)"),
            ("12pm + 33min", "12:33 pm"),
            ("12am + 33min", "12:33 am"),
            ("23:50 + 20min", "00:10 (+1d)"),
        ]
        for (source, expected) in examples {
            XCTAssertEqual(engine.evaluate(source).first?.value, expected, source)
        }
    }

    func testSecondsAndFractionalOffsetsAreVisible() throws {
        let engine = try NumiEngine()
        let examples = [
            ("9pm + 33min + 15sec", "9:33:15 pm"),
            ("9pm + 0.5sec", "9:00:00.5 pm"),
            ("9pm + 60sec", "9:01 pm"),
            ("9pm + 0.5min", "9:00:30 pm"),
            ("23:59 + 59.9999sec", "00:00 (+1d)"),
        ]
        for (source, expected) in examples {
            XCTAssertEqual(engine.evaluate(source).first?.value, expected, source)
        }
    }

    func testInvalidClockRangesDoNotBecomeClockResults() throws {
        let engine = try NumiEngine()
        for source in ["0pm + 33min", "13pm + 33min", "9:60pm + 33min", "24:00 + 33min"] {
            XCTAssertNotEqual(engine.evaluate(source).first?.kind, .timezone, source)
        }
    }

    func testLabelsAndCommentsKeepClockArithmetic() throws {
        let engine = try NumiEngine()
        for source in [
            "Arrival: 9pm + 33min",
            "Arrival: 21:00 + 33min",
            "9pm + 33min // flight time",
            "Arrival: 9pm + 33min \"flight time\"",
        ] {
            let result = engine.evaluate(source).first
            XCTAssertEqual(result?.kind, .timezone, source)
            XCTAssertEqual(result?.value, source.contains("21:00") ? "21:33" : "9:33 pm", source)
        }
    }

    func testPhysicalPicometersAndOrdinaryDurationsRemainQuantities() throws {
        let engine = try NumiEngine()
        for source in ["100pm in nm", "9 picometers + 33mi", "12min + 15min", "33mi in km"] {
            let result = engine.evaluate(source).first
            XCTAssertEqual(result?.kind, .expression, source)
            XCTAssertNotNil(result?.value, source)
        }
        XCTAssertEqual(engine.evaluate("100pm in nm").first?.value, "0.1 nm")
    }

    func testClockResultsDoNotPolluteSumOrPrev() throws {
        let engine = try NumiEngine()
        let result = engine.evaluate("5\n9pm + 33min\n10\nsum\nprev")
        XCTAssertEqual(result[1].kind, .timezone)
        XCTAssertEqual(result[3].value, "15")
        XCTAssertEqual(result[4].value, "15")
    }
}
