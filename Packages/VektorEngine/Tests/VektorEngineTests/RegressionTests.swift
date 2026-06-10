import XCTest
@testable import VektorEngine

/// Regression tests for the 2026-06-10 code-review fixes. Each test pins a
/// bug that shipped because the seam it lives on (handler ↔ aggregator,
/// Swift suggestion list ↔ JS unit table) had no coverage.
@MainActor
final class RegressionTests: XCTestCase {

    // MARK: - Timezone results must not pollute sum / prev
    //
    // Timezone handler results are display strings ("2026-06-10 14:23 CEST
    // (Europe/Berlin)"). They used to be appended to `previousValues` and
    // `aggregateWindow`, so any doc mixing a timezone line with an expense
    // list broke `sum` with a math.js parse error, and `prev` after a tz
    // line substituted the garbage string.

    func testTimezoneLineDoesNotPolluteSum() throws {
        let engine = try NumiEngine()
        let r = engine.evaluate("""
        100
        200
        1430 Berlin in Hong Kong
        sum
        """)
        XCTAssertEqual(r[2].kind, .timezone, "tz line should still resolve as timezone")
        XCTAssertEqual(r.last?.value, "300",
                       "sum must ignore the timezone display string, got: \(String(describing: r.last?.value))")
    }

    func testPrevAfterTimezoneLineRefersToLastNumeric() throws {
        let engine = try NumiEngine()
        let r = engine.evaluate("""
        100
        1430 Berlin in Hong Kong
        prev * 2
        """)
        XCTAssertNotEqual(r.last?.kind, .error,
                          "prev after a tz line must not error: \(String(describing: r.last?.value))")
        XCTAssertEqual(r.last?.value, "200",
                       "prev must skip the timezone display string and use 100")
    }

    // MARK: - Every autocomplete suggestion must evaluate
    //
    // SuggestionEngine used to offer `nautical_mile`, `light_year`,
    // `square_meters`, `watt_hours`, … — names math.js's createUnit
    // silently rejects (underscores) or that were never registered
    // (`milliseconds`, `petabytes`, `kilobits`, long-form SI plurals).
    // Accepting the app's own ghost completion produced an error in the
    // gutter. This sweep guarantees every offered completion resolves.

    func testEverySuggestionTargetUnitEvaluates() throws {
        let engine = try NumiEngine()
        var failures: [String] = []
        for category in UnitCategory.allCases {
            for unit in category.targetUnits {
                let r = engine.evaluate("1 \(unit)").first
                if r?.kind == .error {
                    failures.append("\(category): 1 \(unit) → \(r?.value ?? "nil")")
                }
            }
        }
        XCTAssertTrue(failures.isEmpty,
                      "autocomplete offers units that don't evaluate:\n" + failures.joined(separator: "\n"))
    }

    func testRenamedUnitsConvertCorrectly() throws {
        let engine = try NumiEngine()
        let cases: [(String, String)] = [
            ("10 nauticalmiles in km",     "18.52"),
            ("2 metricton in kg",          "2 000"),
            ("1 kilowatthours in J",       "3 600 000"),
            ("100 sqm in sqft",            "1 076"),
            ("1000 micrograms in mg",      "1"),
            ("8 kilobits in bytes",        "1 000"),
        ]
        for (expr, expected) in cases {
            let r = engine.evaluate(expr).first
            XCTAssertNotEqual(r?.kind, .error, "\(expr) errored: \(r?.value ?? "nil")")
            XCTAssertEqual(r?.value?.contains(expected), true,
                           "\(expr): expected to contain \(expected), got \(r?.value ?? "nil")")
        }
    }
}
