import XCTest
@testable import VektorEngine

final class SuggestionEngineTests: XCTestCase {

    /// Helper: suggest from a string where `|` marks the cursor position.
    private func suggest(_ str: String) -> String? {
        guard let pipe = str.firstIndex(of: "|") else { return nil }
        let cursor = NSRange(str.startIndex..<pipe, in: str).length
        let stripped = str.replacingOccurrences(of: "|", with: "")
        return SuggestionEngine.suggest(in: stripped, cursor: cursor)
    }

    func testKilogramsToPoundsByPrefix() {
        // "10 kg in p|" should suggest "ounds" (completing "pounds")
        XCTAssertEqual(suggest("10 kg in p|"), "ounds")
    }

    func testKilogramsToOuncesByPrefix() {
        XCTAssertEqual(suggest("10 kg in ou|"), "nces")
    }

    func testMassNeverSuggestsCelsius() {
        // Mass source should NOT propose a temperature unit.
        let s = suggest("10 kg in c|")
        if let s {
            XCTAssertFalse(s.lowercased().contains("celsius"),
                           "must not suggest celsius for a mass source: got \(s)")
        }
    }

    func testLengthMatchesMeters() {
        XCTAssertEqual(suggest("1 ft in m|"), "eters")
    }

    func testPressureInHgToHPa() {
        XCTAssertEqual(suggest("29.92 inHg in h|"), "Pa")
    }

    func testNoSuggestionWithoutConversionKeyword() {
        XCTAssertNil(suggest("10 kg p|"))     // missing "in"
        XCTAssertNil(suggest("10 kg|"))       // not yet converting
        XCTAssertNil(suggest("|"))            // empty
    }

    func testSuggestionRespectsCase() {
        // Lower-case prefix "p" still suggests pounds.
        XCTAssertNotNil(suggest("10 kg in P|"))
    }

    func testUnknownSourceUnitNoSuggestion() {
        XCTAssertNil(suggest("10 blarg in p|"))
    }

    func testKnotsSpeedCategory() {
        // Speed source should suggest from speed category, not length etc.
        let s = suggest("120 kt in m|")
        XCTAssertNotNil(s)
        // First match in speed list starting with "m" is "mph" → suffix "ph"
        XCTAssertEqual(s, "ph")
    }

    // MARK: - Extended coverage (units that previously had gaps)

    func testNewtonsRecognisedAsForce() {
        XCTAssertNotNil(suggest("10 newtons in d|"))    // → dynes
        XCTAssertNotNil(suggest("10 N in d|"))
    }

    func testForceSuggestKilonewtons() {
        // "10 N in k|" → either kp or kgf or kilonewtons (first match wins)
        let s = suggest("10 N in k|")
        XCTAssertNotNil(s, "should suggest some k-prefixed force unit")
    }

    func testDecimeterAsSource() {
        // decimeter (length) → meters / centimeters
        XCTAssertNotNil(suggest("10 decimeter in m|"))
        XCTAssertNotNil(suggest("10 dm in m|"))
    }

    func testDecimeterAsTarget() {
        // "1 m in d|" → decimeters (first d-prefixed length)
        XCTAssertEqual(suggest("1 m in d|"), "ecimeters")
    }

    func testHectogramsAsTarget() {
        // "1 kg in h|" → hectograms
        XCTAssertEqual(suggest("1 kg in h|"), "ectograms")
    }

    func testMillinewtonsAsTarget() {
        // "1 N in m|" → meganewtons or millinewtons depending on order; both
        // are valid force units. Just check non-nil.
        XCTAssertNotNil(suggest("1 N in m|"))
    }

    func testNanosecondsAsTarget() {
        // "1 s in n|" → nanoseconds
        XCTAssertEqual(suggest("1 s in n|"), "anoseconds")
    }

    func testMicrolitersAsSource() {
        XCTAssertNotNil(suggest("1 microliter in m|"))
    }

    func testKpaPressureAsSource() {
        // "100 kPa in m|" → mbar / mmHg / megapascals - non-nil expected
        XCTAssertNotNil(suggest("100 kPa in m|"))
    }

    func testGigahertzAsTarget() {
        // "1000 MHz in g|" → gigahertz
        XCTAssertEqual(suggest("1000 MHz in g|"), "igahertz")
    }

    func testBlankDestinationUsesDifferentUnitRatherThanSourceAlias() {
        for source in ["m", "meter", "meters", "metre", "metres"] {
            XCTAssertEqual(suggest("11\(source) in |"), "kilometers", source)
        }
        XCTAssertEqual(suggest("11 ft in |"), "meters")
        XCTAssertEqual(suggest("11 lb in |"), "kilograms")
        XCTAssertEqual(suggest("11 l in |"), "milliliters")
        XCTAssertEqual(suggest("11 s in |"), "minutes")
        XCTAssertEqual(suggest("100 degC in |"), "fahrenheit")
    }

    func testTypedPrefixComesOnlyFromTheDestination() {
        XCTAssertEqual(suggest("11m in k|"), "ilometers")
        XCTAssertEqual(suggest("11m in c|"), "entimeters")
        XCTAssertEqual(suggest("11m in f|"), "eet")
        XCTAssertEqual(suggest("11m in m|"), "illimeters")
        XCTAssertEqual(suggest("11m in p|"), "icometers")
        XCTAssertNil(suggest("11m in z|"))
        XCTAssertEqual(suggest("11ft in f|"), "athom")
    }

    func testAllConversionSeparatorsAndCaseAreSupported() {
        for separator in ["in", "to", "as", "into", "IN", "TO", "AS", "INTO"] {
            XCTAssertEqual(suggest("10 kg \(separator) p|"), "ounds", separator)
        }
        XCTAssertEqual(suggest("10kg\tIN\tp|"), "ounds")
    }

    func testGluedAndSpacedClockMeridiemsNeverSuggestDistance() {
        for time in ["11pm", "11am", "11 pm", "11 AM", "1 PM", "12am", "12PM", "4.30pm", "4.30 pm"] {
            XCTAssertNil(suggest("\(time) in |"), time)
            XCTAssertNil(suggest("\(time) in m|"), time)
        }
    }

    func testClockMinutesAndMilitaryTimeNeverBecomeUnitSources() {
        for time in ["2:30pm", "2:30 pm", "11:30am", "23:30", "09:30", "1430", "0900", "1430Z", "14:30Z"] {
            XCTAssertNil(suggest("\(time) in m|"), time)
            XCTAssertNil(suggest("\(time) Munich time in m|"), time)
        }
    }

    func testExplicitTinyUnitsRemainAvailableDespiteClockCollision() {
        XCTAssertEqual(suggest("11 picometers in m|"), "eters")
        XCTAssertEqual(suggest("11 attometers in m|"), "eters")
        XCTAssertEqual(suggest("100pm in m|"), "eters")
        XCTAssertEqual(suggest("100am in m|"), "eters")
        XCTAssertEqual(suggest("10 mm in m|"), "eters")
        XCTAssertEqual(suggest("10 Mm in m|"), "eters")
    }

    func testClockTokenValidatorChecksWholeTokensAndBounds() {
        for token in ["11pm", "11 pm", "2:30pm", "4.30 pm", "23:30", "1430", "0900", "1430Z", "14:30z", "00:00"] {
            XCTAssertTrue(SuggestionEngine.isClockTime(token), token)
        }
        for token in ["", "11", "11m", "picometers", "0am", "13pm", "100am", "11:60pm", "24:00", "2460", "2360", "4.3pm", "11pm in Berlin", "1430 Munich"] {
            XCTAssertFalse(SuggestionEngine.isClockTime(token), token)
        }
    }

    func testCursorDoesNotInsertCompletionBeforeExistingContent() {
        XCTAssertNil(suggest("1 ft in m|iles"))
        XCTAssertNil(suggest("11m in |foo"))
        XCTAssertEqual(suggest("10 kg in p|  \n11pm in Berlin"), "ounds")
    }

    func testUTF16CursorAndCurrentLineIsolation() {
        XCTAssertEqual(suggest("# 😀 estimate\r\n10 kg in p|"), "ounds")
        XCTAssertNil(suggest("11pm in |\n10 kg in pounds"))
        XCTAssertNil(SuggestionEngine.suggest(in: "10 kg in p", cursor: -1))
        XCTAssertNil(SuggestionEngine.suggest(in: "10 kg in p", cursor: 999))
    }

    func testTemperatureDemoUsesSupportedUnitSyntax() {
        XCTAssertTrue(SuggestionEngine.demoHints.contains("100 degF in degC"))
        XCTAssertFalse(SuggestionEngine.demoHints.contains("100°F in °C"))
    }
}
