import XCTest
@testable import TallyEngine

final class SuggestionEngineTests: XCTestCase {

    /// Helper: suggest from a string where `|` marks the cursor position.
    private func suggest(_ str: String) -> String? {
        guard let pipe = str.firstIndex(of: "|") else { return nil }
        let cursor = str.distance(from: str.startIndex, to: pipe)
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
}
