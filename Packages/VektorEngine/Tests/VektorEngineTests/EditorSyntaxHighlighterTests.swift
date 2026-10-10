import XCTest
@testable import VektorEngine

final class EditorSyntaxHighlighterTests: XCTestCase {
    private let units: Set<String> = ["m", "cm", "km", "kg", "lb", "h", "L", "s", "ft", "min", "hours", "minutes", "degF", "degC", "kt", "inHg", "hPa"]

    private func highlighted(_ source: String) -> [(String, EditorSyntaxHighlighter.Kind)] {
        let text = source as NSString
        return EditorSyntaxHighlighter.tokens(in: source, isKnownUnit: units.contains)
            .filter { $0.kind != .operatorSymbol }.map {
            (text.substring(with: $0.range), $0.kind)
        }
    }

    func testAssignmentsAndLaterReferencesAreCaseInsensitive() {
        let tokens = highlighted("Rate = 85\nhours = 12\nsubtotal = rATE * hours\nsubtotal + 2")
        XCTAssertEqual(tokens.map(\.0), ["Rate", "hours", "subtotal", "rATE", "hours", "subtotal"])
        XCTAssertTrue(tokens.allSatisfy { $0.1 == .variable })
    }

    func testReferencesBeforeDeclarationAndOrdinaryNotesStayNeutral() {
        XCTAssertTrue(highlighted("rate * 2\nMeet in m\nI need 2 m of cable\nUSD is our currency\nMETAR KSFO").isEmpty)
        let tokens = highlighted("rate = 85\nThe rate is negotiable\nrate / 2")
        XCTAssertEqual(tokens.map(\.0), ["rate", "rate"])
    }

    func testHeadersLabelsCommentsAndPageReferencesAreExcluded() {
        let source = "# rent = 10 EUR\n// rate = 85 USD\nBudget in EUR: 100 EUR // 20 USD\nprice = 20\nprice + 2 \"price 50 kg\"\n@price\nprice + 2 @price"
        let tokens = highlighted(source)
        XCTAssertEqual(tokens.map(\.0), ["EUR", "price", "price", "price"])
        XCTAssertEqual(tokens.map(\.1), [.unit, .variable, .variable, .variable])
    }

    func testNumericUnitsConversionsCompoundsAndCurrencySymbols() {
        let tokens = highlighted("120 kt in km/h\n100 EUR in usd\n$20 + 10€\n2.5kg in lb\n100 cm in m")
        XCTAssertEqual(tokens.map(\.0), ["kt", "km", "h", "EUR", "usd", "$", "€", "kg", "lb", "cm", "m"])
        XCTAssertTrue(tokens.allSatisfy { $0.1 == .unit })
    }

    func testUnitAndVariableCollisionsPreferDeclaredVariables() {
        let tokens = highlighted("m = 2\nm * 3\n2m\n100 cm in m")
        XCTAssertEqual(tokens.map(\.0), ["m", "m", "m", "cm", "m"])
        XCTAssertEqual(tokens.map(\.1), [.variable, .variable, .variable, .unit, .variable])
    }

    func testAmbiguousInAndNumericScalesStayNeutral() {
        let tokens = highlighted("10 mi in km\n1 in in cm\n3 ft 6 in in cm\n2 M EUR\n5 k USD\n1 B EUR")
        // mi is intentionally absent from this test's registry: its line
        // must remain neutral rather than color a guessed conversion.
        XCTAssertEqual(tokens.map(\.0), ["in", "cm", "ft", "in", "cm", "EUR", "USD", "EUR"])
    }

    func testMinutesTakeUnitPriorityAndBareAggregateStaysNeutral() {
        let tokens = highlighted("2 min\nprev in min\nmin\n1 in")
        XCTAssertEqual(tokens.map(\.0), ["min", "min", "in"])
        XCTAssertTrue(tokens.allSatisfy { $0.1 == .unit })
    }

    func testQuotedNotesDoNotConsumeFeetInchesNotation() {
        let tokens = highlighted("12'6\" in cm\n100 kg \"20 USD and rate\"\n100 kg // 20 EUR")
        XCTAssertEqual(tokens.map(\.0), ["cm", "kg", "kg"])
    }

    func testUTF16RangesSurviveEmojiUnicodeIdentifiersAndCRLF() {
        let source = "// 😀 example\r\nRésumé = 2 kg\r\nrésumé * 3\r\n"
        let ns = source as NSString
        let tokens = EditorSyntaxHighlighter.tokens(in: source, isKnownUnit: units.contains)
        XCTAssertEqual(tokens.map { ns.substring(with: $0.range) }, ["Résumé", "=", "kg", "résumé", "*"])
        XCTAssertEqual(tokens[0].range, ns.range(of: "Résumé"))
        XCTAssertEqual(tokens[1].range, ns.range(of: "="))
        XCTAssertEqual(tokens[2].range, ns.range(of: "kg"))
        XCTAssertEqual(tokens[3].range, ns.range(of: "résumé"))
        XCTAssertEqual(tokens, EditorSyntaxHighlighter.tokens(in: source, isKnownUnit: units.contains))
    }

    func testOnlyPlausibleDistinctUnitCandidatesCallThePredicate() {
        var queried: [String] = []
        let source = "A note about kilograms and USD\nMeet in m\n2 kg\n3 kg\n100 EUR in USD\n"
        let tokens = EditorSyntaxHighlighter.tokens(in: source) { token in
            queried.append(token)
            return self.units.contains(token)
        }
        XCTAssertEqual(queried, ["kg"])
        XCTAssertEqual(tokens.count, 4)
    }

    func testDefinitionsDoNotLeakBetweenDocuments() {
        XCTAssertEqual(highlighted("rate = 85\nrate * 2").count, 2)
        XCTAssertTrue(highlighted("rate * 2").isEmpty)
    }

    func testMathOperatorsAreColouredWithoutNumbersOrGrouping() {
        let source = "rate = 85\n(rate + 3) * 2 / 5 - 25% of rate\n2^3 >= 7\nsqrt(4) × 2 ÷ 4\n5−2\n1!=0\n1&&1"
        let ns = source as NSString
        let operators = EditorSyntaxHighlighter.tokens(in: source, isKnownUnit: units.contains)
            .filter { $0.kind == .operatorSymbol }
        XCTAssertEqual(operators.map { ns.substring(with: $0.range) },
                       ["=", "+", "*", "/", "-", "%", "^", ">", "=", "×", "÷", "−", "!", "=", "&", "&"])
    }

    func testOperatorsRespectNotesHeadersLabelsAndTrailingComments() {
        let source = "# 2 + 2\n// 3 * 4\nKeep + symbol in this note\nhttps://example.com\nTips - tax: 100 + 20 // 5 / 2\n2 * 3 \"4 + 5\""
        let ns = source as NSString
        let operators = EditorSyntaxHighlighter.tokens(in: source, isKnownUnit: units.contains)
            .filter { $0.kind == .operatorSymbol }
        XCTAssertEqual(operators.map { ns.substring(with: $0.range) }, ["+", "*"])
    }

    func testUnfinishedAssignmentKeepsItsOperatorColour() {
        let source = "rate = unfin"
        let ns = source as NSString
        let tokens = EditorSyntaxHighlighter.tokens(in: source, isKnownUnit: units.contains)
        XCTAssertEqual(tokens.map { ns.substring(with: $0.range) }, ["rate", "="])
        XCTAssertEqual(tokens.map(\.kind), [.variable, .operatorSymbol])
    }

    func testClockSuffixesAreNotPhysicalUnitTokens() {
        let source = "11pm in\n11 am in\n2:30pm in\n4.30pm in\n11 picometers in m"
        let ns = source as NSString
        let tokens = EditorSyntaxHighlighter.tokens(in: source) {
            self.units.contains($0) || ["am", "pm", "picometers"].contains($0)
        }
        XCTAssertEqual(tokens.map { ns.substring(with: $0.range) }, ["picometers", "m"])
        XCTAssertTrue(tokens.allSatisfy { $0.kind == .unit })
    }

    func testClockArithmeticKeepsMeridiemNeutralAndTintsDurationUnits() {
        let source = "9pm + 33min\n9pm + 33mi\n11:45pm + 30min\n12:10am - 20min\n9 pm + 1h - 15min"
        let ns = source as NSString
        let tokens = EditorSyntaxHighlighter.tokens(in: source) {
            self.units.contains($0) || ["am", "pm", "mi"].contains($0)
        }
        XCTAssertEqual(tokens.map { ns.substring(with: $0.range) },
                       ["+", "min", "+", "mi", "+", "min", "-", "min", "+", "h", "-", "min"])
        XCTAssertEqual(tokens.map(\.kind),
                       [.operatorSymbol, .unit, .operatorSymbol, .unit,
                        .operatorSymbol, .unit, .operatorSymbol, .unit,
                        .operatorSymbol, .unit, .operatorSymbol, .unit])
    }

    func testPhysicalPicometersAndAttometersStillReceiveUnitTint() {
        let source = "100pm + 33min\n100am - 1m\n9 picometers + 3 mi"
        let ns = source as NSString
        let tokens = EditorSyntaxHighlighter.tokens(in: source) {
            self.units.contains($0) || ["am", "pm", "picometers", "mi"].contains($0)
        }
        XCTAssertEqual(tokens.filter { $0.kind == .unit }.map { ns.substring(with: $0.range) },
                       ["pm", "min", "am", "m", "picometers", "mi"])
    }

    func testClockArithmeticHonoursLabelsAndExcludesOrdinaryNotes() {
        let source = "Flight: 9pm + 33min // 2am - 4h\nMeet at 9pm + 33min\n# 9pm + 33min\n// 12am - 1h"
        let ns = source as NSString
        let tokens = EditorSyntaxHighlighter.tokens(in: source) {
            self.units.contains($0) || ["am", "pm"].contains($0)
        }
        XCTAssertEqual(tokens.map { ns.substring(with: $0.range) }, ["+", "min"])
        XCTAssertEqual(tokens.map(\.kind), [.operatorSymbol, .unit])
    }

    @MainActor
    func testRealUnitClassifierAndCanonicalExamples() throws {
        let engine = try NumiEngine()
        for unit in ["km", "h", "degC", "degF", "hPa", "inHg", "kt", "eur", "Eur", "USD"] {
            XCTAssertTrue(engine.isKnownDisplayUnit(unit), unit)
        }
        for unit in ["unknown_unit", "foo", "kg'", "kg\\", "'); alert(1); ('", ""] {
            XCTAssertFalse(engine.isKnownDisplayUnit(unit), unit)
        }
        let source = "120 kt in km/h\n29.92 inHg in hPa\n100 degF in degC"
        let ns = source as NSString
        let tokens = EditorSyntaxHighlighter.tokens(in: source, isKnownUnit: engine.isKnownDisplayUnit)
        XCTAssertEqual(tokens.map { ns.substring(with: $0.range) }, ["kt", "km", "/", "h", "inHg", "hPa", "degF", "degC"])
        XCTAssertEqual(tokens.filter { $0.kind == .operatorSymbol }.count, 1)
        XCTAssertEqual(engine.evaluate("1 in").first?.kind, .expression)
    }
}
