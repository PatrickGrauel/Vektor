import XCTest
@testable import TallyEngine

@MainActor
final class NumiEngineTests: XCTestCase {

    func testBasicArithmetic() throws {
        let engine = try NumiEngine()
        let results = engine.evaluate("2 + 2")
        XCTAssertEqual(results.first?.kind, .expression)
        XCTAssertEqual(results.first?.value, "4")
    }

    func testWordOperator() throws {
        let engine = try NumiEngine()
        let results = engine.evaluate("8 times 9")
        XCTAssertEqual(results.first?.value, "72")
    }

    func testUnitConversion() throws {
        let engine = try NumiEngine()
        let results = engine.evaluate("1 m to cm")
        XCTAssertEqual(results.first?.kind, .expression)
        XCTAssertEqual(results.first?.value?.contains("100"), true)
    }

    func testNumiInToConversion() throws {
        let engine = try NumiEngine()
        // Numi syntax: "1 meter in cm"
        let results = engine.evaluate("1 meter in cm")
        XCTAssertEqual(results.first?.kind, .expression)
        XCTAssertEqual(results.first?.value?.contains("100"), true)
    }

    func testPercentageOff() throws {
        let engine = try NumiEngine()
        let results = engine.evaluate("100 - 5%")
        XCTAssertEqual(results.first?.kind, .expression)
        XCTAssertEqual(results.first?.value, "95")
    }

    func testPercentageOfValue() throws {
        let engine = try NumiEngine()
        let results = engine.evaluate("20% of 50")
        XCTAssertEqual(results.first?.value, "10")
    }

    func testHeader() throws {
        let engine = try NumiEngine()
        let results = engine.evaluate("# My header")
        XCTAssertEqual(results.first?.kind, .header)
    }

    func testComment() throws {
        let engine = try NumiEngine()
        let results = engine.evaluate("// just a note")
        XCTAssertEqual(results.first?.kind, .comment)
    }

    func testLabel() throws {
        let engine = try NumiEngine()
        let results = engine.evaluate("Price: 10 + 5")
        XCTAssertEqual(results.first?.kind, .expression)
        XCTAssertEqual(results.first?.value, "15")
    }

    func testPrev() throws {
        let engine = try NumiEngine()
        let results = engine.evaluate("""
        10 + 5
        prev * 2
        """)
        XCTAssertEqual(results[0].value, "15")
        XCTAssertEqual(results[1].value, "30")
    }

    func testSumAggregate() throws {
        let engine = try NumiEngine()
        let results = engine.evaluate("""
        10
        20
        30
        sum
        """)
        XCTAssertEqual(results[3].value, "60")
    }

    func testAverageAggregate() throws {
        let engine = try NumiEngine()
        let results = engine.evaluate("""
        10
        20
        30
        average
        """)
        XCTAssertEqual(results[3].value, "20")
    }

    func testScaleK() throws {
        let engine = try NumiEngine()
        let results = engine.evaluate("2k + 500")
        // Output groups thousands with a space: "2 500".
        XCTAssertEqual(results.first?.value, "2 500")
    }

    func testCurrencySymbolNoFX() throws {
        // Without FX setup, $20 should at least parse as "20 USD" and yield a unit value
        let engine = try NumiEngine()
        let results = engine.evaluate("$20")
        XCTAssertEqual(results.first?.kind, .expression)
        XCTAssertEqual(results.first?.value?.contains("USD"), true)
    }

    // MARK: - Variables persist across lines (issue: 'House = 100k EUR; House * 2')

    func testVariablesPersist() throws {
        let engine = try NumiEngine()
        let results = engine.evaluate("""
        a = 12
        b = 2
        a * b
        """)
        XCTAssertEqual(results[0].kind, .expression)
        XCTAssertEqual(results[0].value, "12")
        XCTAssertEqual(results[1].value, "2")
        XCTAssertEqual(results[2].kind, .expression)
        XCTAssertEqual(results[2].value, "24")
    }

    func testVariablesWithScalesAndUnits() throws {
        let engine = try NumiEngine()
        // Big numbers should NOT format as scientific (no '1e+5').
        let snap = FXService.Snapshot(
            base: "USD",
            ratesPerUSD: ["USD": 1.0, "EUR": 0.9],
            timestamp: Date()
        )
        engine.applyFX(snap)
        let results = engine.evaluate("""
        House = 100k EUR
        House * 2
        """)
        XCTAssertEqual(results[0].kind, .expression)
        let firstValue = results[0].value ?? ""
        XCTAssertFalse(firstValue.contains("e+"), "expected non-exponential, got: \(firstValue)")
        XCTAssertTrue(firstValue.contains("EUR"))
        XCTAssertEqual(results[1].kind, .expression)
        let secondValue = results[1].value ?? ""
        XCTAssertFalse(secondValue.contains("e+"))
        XCTAssertTrue(secondValue.contains("EUR"))
    }

    func testFreshScopeBetweenEvaluations() throws {
        let engine = try NumiEngine()
        // First evaluation: define a.
        _ = engine.evaluate("a = 5")
        // Second evaluation: 'a' should be undefined (fresh document).
        let results = engine.evaluate("a + 1")
        XCTAssertEqual(results.first?.kind, .error)
    }

    func testMilitaryTimeConversion() throws {
        let engine = try NumiEngine()
        let results = engine.evaluate("1430 Berlin in Hong Kong")
        XCTAssertEqual(results.first?.kind, .timezone)
        XCTAssertNotNil(results.first?.value)
    }

    func testZuluAlias() throws {
        let engine = try NumiEngine()
        let r1 = engine.evaluate("1430 Berlin in Zulu").first
        XCTAssertEqual(r1?.kind, .timezone)
        XCTAssertNotNil(r1?.value)
        let r2 = engine.evaluate("1200 Z in Berlin").first
        XCTAssertEqual(r2?.kind, .timezone)
    }

    // MARK: - Zulu + N offset arithmetic

    func testZuluPlusHours() throws {
        let engine = try NumiEngine()
        let r = engine.evaluate("1430 Zulu + 2").first
        XCTAssertEqual(r?.kind, .timezone, "got: \(String(describing: r))")
        // 14:30 UTC + 2h = 16:30 UTC. The bridge formats with "HH:mm zzz".
        XCTAssertTrue((r?.value ?? "").contains("16:30"),
                      "expected 16:30 in result, got: \(r?.value ?? "nil")")
    }

    func testBerlinPlusMinutes() throws {
        let engine = try NumiEngine()
        let r = engine.evaluate("14:30 Berlin + 90m").first
        XCTAssertEqual(r?.kind, .timezone)
        XCTAssertTrue((r?.value ?? "").contains("16:00"),
                      "expected 16:00 in result, got: \(r?.value ?? "nil")")
    }

    func testBareZuluPlusOffset() throws {
        // "Zulu + 2" should give current UTC + 2 hours
        let engine = try NumiEngine()
        let r = engine.evaluate("Zulu + 2").first
        XCTAssertEqual(r?.kind, .timezone)
        XCTAssertNotNil(r?.value)
    }

    // MARK: - "now" + offset

    func testNowPlusMinutes() throws {
        let engine = try NumiEngine()
        let r = engine.evaluate("now + 52min").first
        XCTAssertEqual(r?.kind, .timezone)
        XCTAssertNotNil(r?.value)
    }

    func testNowChainedOffsets() throws {
        let engine = try NumiEngine()
        let r = engine.evaluate("now + 2h + 52min").first
        XCTAssertEqual(r?.kind, .timezone)
        XCTAssertNotNil(r?.value)
    }

    func testZuluPlusMinutes() throws {
        let engine = try NumiEngine()
        let r = engine.evaluate("Zulu + 52min").first
        XCTAssertEqual(r?.kind, .timezone)
        XCTAssertNotNil(r?.value)
    }

    // MARK: - Plain time arithmetic via mathjs (12 min + 15 min)

    func testMinutesAdd() throws {
        let engine = try NumiEngine()
        let r = engine.evaluate("12 min + 15 min").first
        XCTAssertEqual(r?.kind, .expression, "got: \(String(describing: r))")
        XCTAssertTrue((r?.value ?? "").contains("27"),
                      "expected 27 minutes total, got: \(r?.value ?? "nil")")
    }

    func testMinutesAddNoSpace() throws {
        let engine = try NumiEngine()
        let r = engine.evaluate("12min + 15min").first
        XCTAssertEqual(r?.kind, .expression)
        XCTAssertTrue((r?.value ?? "").contains("27"))
    }

    // MARK: - Aviation units

    func testNauticalMile() throws {
        let engine = try NumiEngine()
        let r = engine.evaluate("100 NM in km").first
        XCTAssertEqual(r?.kind, .expression)
        // 100 NM = 185.2 km
        XCTAssertTrue((r?.value ?? "").contains("185"))
    }

    func testKnotsShorthand() throws {
        let engine = try NumiEngine()
        let r = engine.evaluate("120 kt in km/h").first
        XCTAssertEqual(r?.kind, .expression)
        // 120 kt ≈ 222.24 km/h
        XCTAssertTrue((r?.value ?? "").contains("222"))
    }

    func testInHgToHPa() throws {
        let engine = try NumiEngine()
        let r = engine.evaluate("29.92 inHg in hPa").first
        XCTAssertEqual(r?.kind, .expression)
        // 29.92 inHg ≈ 1013.2 hPa — formatted as "1 013 hPa" (thousands-grouped).
        XCTAssertTrue((r?.value ?? "").contains("1 013"),
                      "expected 1 013 in result, got: \(r?.value ?? "nil")")
    }

    func testFlightLevel() throws {
        let engine = try NumiEngine()
        // Pilots write "FL250", which the preprocessor rewrites to "250 FL".
        let r = engine.evaluate("FL250 in ft").first
        XCTAssertEqual(r?.kind, .expression, "got: \(String(describing: r))")
        XCTAssertTrue((r?.value ?? "").contains("25 000"),
                      "expected 25 000 ft, got \(r?.value ?? "nil")")
    }

    // MARK: - Variable assignment with currency (without OXR key)

    func testVariableWithCurrencyPlaceholderRate() throws {
        // Before this fix, `b = 5000 EUR` failed silently because EUR wasn't
        // a registered unit, so `b * 2` resolved to "2 b" (the bit unit).
        let engine = try NumiEngine()
        let results = engine.evaluate("""
        b = 5000 EUR
        b * 2
        """)
        XCTAssertEqual(results[0].kind, .expression)
        XCTAssertEqual(results[1].kind, .expression)
        let secondValue = results[1].value ?? ""
        // Thousands separator: "10 000 EUR".
        XCTAssertTrue(secondValue.contains("10 000"),
                      "expected 10 000 EUR, got: \(secondValue)")
        XCTAssertTrue(secondValue.contains("EUR") || secondValue.contains("eur"),
                      "expected EUR unit, got: \(secondValue)")
    }

    // MARK: - Headers with no space (#Header)

    func testHeaderNoSpace() throws {
        let engine = try NumiEngine()
        let r = engine.evaluate("#Trip to Bali").first
        XCTAssertEqual(r?.kind, .header)
    }

    // MARK: - Comma decimals (European locale convention)

    func testCommaDecimalSimple() throws {
        let engine = try NumiEngine()
        // 1,8 means 1.8 in European notation
        let r = engine.evaluate("1,8 + 0,2").first
        XCTAssertEqual(r?.kind, .expression)
        XCTAssertEqual(r?.value, "2")
    }

    func testCommaDecimalWithUnit() throws {
        let engine = try NumiEngine()
        let r = engine.evaluate("1,5 m to cm").first
        XCTAssertEqual(r?.kind, .expression)
        XCTAssertEqual(r?.value?.contains("150"), true)
    }

    func testCommaDecimalLeftAlone_FunctionCall() throws {
        let engine = try NumiEngine()
        // min() args mustn't be munged into "min(1.2)"
        let r = engine.evaluate("min(1, 2)").first
        XCTAssertEqual(r?.value, "1")
    }

    // MARK: - hh:mm:ss formatting

    func testHmsFromHours() throws {
        let engine = try NumiEngine()
        let r = engine.evaluate("1,8 h in hh:mm:ss").first
        XCTAssertEqual(r?.kind, .expression)
        // 1.8 h = 1h 48m 0s
        XCTAssertEqual(r?.value, "01:48:00")
    }

    func testHmsFromSeconds() throws {
        let engine = try NumiEngine()
        let r = engine.evaluate("3725 seconds in hh:mm:ss").first
        XCTAssertEqual(r?.value, "01:02:05")
    }

    func testHmFromMinutes() throws {
        let engine = try NumiEngine()
        let r = engine.evaluate("125 minutes in hh:mm").first
        XCTAssertEqual(r?.value, "02:05")
    }

    // MARK: - METAR Zulu observation time parsing

    func testMetarObservationTimeParsed() {
        // Real EDDM METAR — observation at day 13, 11:50 UTC.
        let raw = "METAR EDDM 131150Z AUTO 23012KT CAVOK 14/02 Q1006"
        let date = NumiEngine.observationTime(in: raw)
        XCTAssertNotNil(date)
        guard let d = date else { return }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let comps = cal.dateComponents([.day, .hour, .minute], from: d)
        XCTAssertEqual(comps.day, 13)
        XCTAssertEqual(comps.hour, 11)
        XCTAssertEqual(comps.minute, 50)
    }

    func testMetarObservationTimeMissing() {
        // Missing the standard DDHHmmZ — return nil so callers fall back.
        XCTAssertNil(NumiEngine.observationTime(in: "METAR XXXX no time here"))
    }

    // MARK: - TAF validity parsing & freshness thresholds

    func testTafValidityShort() {
        // 9 hours total (06Z–15Z same day)
        let raw = "TAF EDDM 130500Z 1306/1315 27010KT 9999 BKN020"
        XCTAssertEqual(NumiEngine.tafValidityHours(in: raw), 9)
    }

    func testTafValidityStandard() {
        // 30 hours total (06Z day 13 → 12Z day 14)
        let raw = "TAF KSFO 130200Z 1306/1412 28006KT P6SM FEW008 OVC020"
        XCTAssertEqual(NumiEngine.tafValidityHours(in: raw), 30)
    }

    func testTafValidityMonthRollover() {
        // 30 hours total across a month boundary (last day → 1st of next)
        let raw = "TAF EGLL 311800Z 3118/0124 27010KT 9999"
        XCTAssertEqual(NumiEngine.tafValidityHours(in: raw), 30)
    }

    func testTafToneShortValidityThresholds() {
        // Short TAF (9h validity): issued every 3h → fresh ≤ 3h 30m,
        // stale 3h 30m–6h, outdated > 6h.
        let raw = "TAF EDDM 130500Z 1306/1315 27010KT"
        XCTAssertEqual(
            NumiEngine.freshnessTone(for: raw, kind: .taf, ageSeconds: 120 * 60),
            .fresh, "2h old short TAF should be fresh")
        XCTAssertEqual(
            NumiEngine.freshnessTone(for: raw, kind: .taf, ageSeconds: 4 * 60 * 60),
            .stale, "4h old short TAF should be stale")
        XCTAssertEqual(
            NumiEngine.freshnessTone(for: raw, kind: .taf, ageSeconds: 7 * 60 * 60),
            .outdated, "7h old short TAF should be outdated")
    }

    func testTafToneStandardValidityThresholds() {
        // Standard TAF (30h validity): issued every 6h → fresh ≤ 6h 30m,
        // stale 6h 30m–12h, outdated > 12h.
        let raw = "TAF KSFO 130200Z 1306/1412 28006KT"
        XCTAssertEqual(
            NumiEngine.freshnessTone(for: raw, kind: .taf, ageSeconds: 5 * 60 * 60),
            .fresh, "5h old standard TAF should be fresh")
        XCTAssertEqual(
            NumiEngine.freshnessTone(for: raw, kind: .taf, ageSeconds: 8 * 60 * 60),
            .stale, "8h old standard TAF should be stale")
        XCTAssertEqual(
            NumiEngine.freshnessTone(for: raw, kind: .taf, ageSeconds: 13 * 60 * 60),
            .outdated, "13h old standard TAF should be outdated")
    }

    // MARK: - Error humanisation

    func testHumaniseUnknownSymbol() {
        XCTAssertEqual(
            NumiEngine.humaniseError("Undefined symbol foo"),
            "Unknown unit or name 'foo' — check spelling."
        )
    }

    func testHumaniseMissingParen() {
        XCTAssertEqual(
            NumiEngine.humaniseError("Parenthesis ) expected (char 9)"),
            "Missing closing parenthesis."
        )
    }

    func testHumaniseStripsCharSuffix() {
        XCTAssertEqual(
            NumiEngine.humaniseError("Something went wrong (char 12)"),
            "Something went wrong"
        )
    }

    func testHumaniseDivisionByZero() {
        XCTAssertEqual(
            NumiEngine.humaniseError("Division by zero"),
            "Division by zero."
        )
    }

    func testMetarToneUnchangedByTafCadence() {
        // METAR thresholds remain 35 / 70 min regardless of the report
        // text — pilots see SPECI / METAR updates frequently.
        let raw = "METAR EDDM 131150Z AUTO 23012KT CAVOK"
        XCTAssertEqual(
            NumiEngine.freshnessTone(for: raw, kind: .metar, ageSeconds: 20 * 60),
            .fresh)
        XCTAssertEqual(
            NumiEngine.freshnessTone(for: raw, kind: .metar, ageSeconds: 50 * 60),
            .stale)
        XCTAssertEqual(
            NumiEngine.freshnessTone(for: raw, kind: .metar, ageSeconds: 90 * 60),
            .outdated)
    }

    // MARK: - Percentage LHS anchoring

    func testPercentBindsToImmediateOperand() throws {
        // Regression: `2 + 100 - 5%` used to greedy-match the whole `2 + 100`
        // as the LHS of the `-5%`, returning ≈ 96.9. The user means
        // `2 + (100 - 5%) = 97`.
        let engine = try NumiEngine()
        XCTAssertEqual(engine.evaluate("2 + 100 - 5%").first?.value, "97")
    }

    func testPercentAdditionAlsoLocalised() throws {
        let engine = try NumiEngine()
        // `10 + 100 + 5%` → 10 + (100 + 5%) = 10 + 105 = 115
        XCTAssertEqual(engine.evaluate("10 + 100 + 5%").first?.value, "115")
    }

    func testPercentStandaloneStillWorks() throws {
        let engine = try NumiEngine()
        XCTAssertEqual(engine.evaluate("100 - 5%").first?.value, "95")
    }

    // MARK: - prev across blank lines

    func testPrevSurvivesBlankLines() throws {
        let engine = try NumiEngine()
        let r = engine.evaluate("10\n\nprev * 2")
        XCTAssertEqual(r[0].value, "10")
        XCTAssertEqual(r[2].value, "20")
    }

    // MARK: - Unit conversion followed by arithmetic

    func testCurrencyConversionThenMultiply() throws {
        // After `100 EUR in IDR`, the result is a unit. Multiplying by a
        // scalar must apply to that unit, not error out.
        let engine = try NumiEngine()
        let r = engine.evaluate("100 EUR in IDR * 2").first
        XCTAssertEqual(r?.kind, .expression)
        // We don't pin the numeric result (depends on live rate) but it
        // must contain "IDR" and not be an error.
        XCTAssertNotEqual(r?.kind, .error)
        XCTAssertTrue((r?.value ?? "").localizedCaseInsensitiveContains("IDR"),
                      "expected IDR unit, got: \(r?.value ?? "")")
    }

    func testUnitConversionThenMultiply() throws {
        // Same shape for non-currency units.
        let engine = try NumiEngine()
        let r = engine.evaluate("1 m in cm * 2").first
        XCTAssertEqual(r?.kind, .expression)
        // 1 m → 100 cm → * 2 = 200 cm
        XCTAssertTrue((r?.value ?? "").contains("200"),
                      "expected 200 cm, got: \(r?.value ?? "")")
    }

    func testCurrencySumThenConvert() throws {
        // Regression: `100 EUR + 25 USD in USD` used to auto-display in
        // EUR (the leading operand's unit) because `to` has higher
        // precedence than `+`. Now wraps the additive expression so the
        // conversion applies to the whole sum.
        let engine = try NumiEngine()
        let r = engine.evaluate("100 EUR + 25 USD in USD").first
        XCTAssertEqual(r?.kind, .expression)
        XCTAssertTrue(
            (r?.value ?? "").localizedCaseInsensitiveContains("USD"),
            "expected sum to be displayed in USD, got: \(r?.value ?? "")"
        )
    }

    func testUnitDifferenceThenConvert() throws {
        let engine = try NumiEngine()
        let r = engine.evaluate("50 m - 20 m in cm").first
        XCTAssertEqual(r?.kind, .expression)
        // 50m − 20m = 30m = 3000 cm
        XCTAssertTrue(
            (r?.value ?? "").contains("3 000") || (r?.value ?? "").contains("3000"),
            "expected 3 000 cm, got: \(r?.value ?? "")"
        )
    }

    // MARK: - sum / average with unit awareness

    func testSumPlainNumbers() throws {
        // Regression for thousands-grouping bug: `1 800` was being read by
        // mathjs as `1 × 800`. With the strip in place sum is honest.
        let engine = try NumiEngine()
        let r = engine.evaluate("""
        100
        200
        300
        sum
        """)
        XCTAssertEqual(r.last?.value, "600")
    }

    func testSumLargeNumbersAcrossThousandsBoundary() throws {
        let engine = try NumiEngine()
        let r = engine.evaluate("""
        1000
        2000
        sum
        """)
        // 3000 with grouping = "3 000".
        XCTAssertEqual(r.last?.value, "3 000")
    }

    func testSumMixedCurrenciesDefaultsToLastUnit() throws {
        // `100 USD / 200 USD / 300 EUR / sum` → result in EUR (last seen).
        let engine = try NumiEngine()
        let r = engine.evaluate("""
        100 USD
        200 USD
        300 EUR
        sum
        """)
        let last = r.last?.value ?? ""
        XCTAssertTrue(last.localizedCaseInsensitiveContains("EUR"),
                      "expected sum in EUR (last seen unit), got: \(last)")
    }

    func testSumExplicitTargetCurrency() throws {
        let engine = try NumiEngine()
        let r = engine.evaluate("""
        100 USD
        200 USD
        sum in EUR
        """)
        let last = r.last?.value ?? ""
        XCTAssertTrue(last.localizedCaseInsensitiveContains("EUR"),
                      "expected explicit EUR target, got: \(last)")
    }

    func testSumExplicitTargetLength() throws {
        let engine = try NumiEngine()
        let r = engine.evaluate("""
        1 m
        2 m
        sum in cm
        """)
        let last = r.last?.value ?? ""
        // 3m = 300 cm
        XCTAssertTrue(last.contains("300") && last.localizedCaseInsensitiveContains("cm"),
                      "expected 300 cm, got: \(last)")
    }

    func testAverageWithUnits() throws {
        let engine = try NumiEngine()
        let r = engine.evaluate("""
        100 USD
        200 USD
        300 USD
        average
        """)
        let last = r.last?.value ?? ""
        XCTAssertTrue(last.contains("200"),
                      "expected average 200 USD, got: \(last)")
    }

    // MARK: - Aliases and edge cases for sum / average

    func testTotalAliasMatchesSum() throws {
        // `total` is documented as an alias for `sum`. Pin it so a future
        // preprocessor edit can't quietly drop it from the regex.
        let engine = try NumiEngine()
        let sumDoc = engine.evaluate("""
        10
        20
        30
        sum
        """)
        let totalDoc = engine.evaluate("""
        10
        20
        30
        total
        """)
        XCTAssertEqual(sumDoc.last?.value, totalDoc.last?.value,
                       "total must produce the same result as sum")
    }

    func testAvgAliasMatchesAverage() throws {
        // `avg` is documented as an alias for `average`.
        let engine = try NumiEngine()
        let avgDoc = engine.evaluate("""
        10
        20
        30
        avg
        """)
        let averageDoc = engine.evaluate("""
        10
        20
        30
        average
        """)
        XCTAssertEqual(avgDoc.last?.value, averageDoc.last?.value,
                       "avg must produce the same result as average")
    }

    func testSumWithCommaDecimals() throws {
        // The comma-decimal preprocessor runs before aggregates, so
        // continental notation should sum cleanly.
        let engine = try NumiEngine()
        let r = engine.evaluate("""
        1,5 m
        2,5 m
        sum
        """)
        let last = r.last?.value ?? ""
        XCTAssertTrue(last.contains("4") && last.localizedCaseInsensitiveContains("m"),
                      "expected 4 m, got: \(last)")
    }

    func testAverageMixedCurrenciesDefaultsToLastUnit() throws {
        // Mirror of testSumMixedCurrenciesDefaultsToLastUnit: average should
        // also default to the last seen unit when none is given explicitly.
        let engine = try NumiEngine()
        let r = engine.evaluate("""
        100 USD
        200 USD
        300 EUR
        average
        """)
        let last = r.last?.value ?? ""
        XCTAssertTrue(last.localizedCaseInsensitiveContains("EUR"),
                      "expected average in EUR (last seen unit), got: \(last)")
    }

    func testSumPreservesScopeAcrossBlankLine() throws {
        // Blank lines must NOT reset previousValues — users intentionally
        // space related calculations apart.
        let engine = try NumiEngine()
        let r = engine.evaluate("""
        10
        20

        30
        sum
        """)
        XCTAssertEqual(r.last?.value, "60",
                       "blank lines should not break running aggregates")
    }

    func testAggregateOnEmptyDocumentReturnsZero() throws {
        // `sum` / `average` with no prior numeric lines must return 0
        // (preprocessor short-circuits at NumiPreprocessor.swift:697).
        let engine = try NumiEngine()
        XCTAssertEqual(engine.evaluate("sum").last?.value, "0")
        XCTAssertEqual(engine.evaluate("average").last?.value, "0")
    }

    // MARK: - Currency case-insensitivity
    //
    // mathjs treats unit names as case-sensitive, so without normalisation
    // `100 eur` and `100 Eur` would fail even though `100 EUR` works. The
    // preprocessor's `rewriteCurrencyCase` pass uppercases known currency
    // tokens when they appear in a unit position (after a number, or after
    // `in`/`to`/`as`).

    func testLowercaseCurrencyEvaluatesSameAsUppercase() throws {
        let engine = try NumiEngine()
        let lower = engine.evaluate("100 eur").first?.value ?? ""
        let upper = engine.evaluate("100 EUR").first?.value ?? ""
        XCTAssertFalse(upper.isEmpty)
        XCTAssertEqual(lower, upper,
                       "100 eur and 100 EUR must produce the same result")
    }

    func testMixedCaseCurrencyEvaluatesSameAsUppercase() throws {
        let engine = try NumiEngine()
        let mixed = engine.evaluate("100 Eur").first?.value ?? ""
        let upper = engine.evaluate("100 EUR").first?.value ?? ""
        XCTAssertEqual(mixed, upper,
                       "100 Eur and 100 EUR must produce the same result")
    }

    func testConversionAcceptsLowercaseTargetCurrency() throws {
        // `in usd` / `to usd` should normalise to `to USD` and convert.
        let engine = try NumiEngine()
        let r = engine.evaluate("100 EUR in usd").first?.value ?? ""
        XCTAssertTrue(r.localizedCaseInsensitiveContains("USD"),
                      "expected a result in USD, got: \(r)")
    }

    func testConversionAcceptsAllLowercase() throws {
        let engine = try NumiEngine()
        let r = engine.evaluate("100 eur in usd").first?.value ?? ""
        XCTAssertTrue(r.localizedCaseInsensitiveContains("USD"),
                      "expected a result in USD, got: \(r)")
    }

    // MARK: - Altitude / Briefing
    //
    // `altitude EDMA` produces field elevation + PA + DA derived from
    // the cached METAR. Without a cached METAR (which is the common
    // case in unit tests, since the bridge starts cold), the fallback
    // path returns elevation only with a "PA/DA need METAR" note.
    // `briefing EDMA` composes METAR + TAF + RWY + ALT.

    func testAltitudeLineRecognised() throws {
        let engine = try NumiEngine()
        let r = engine.evaluate("altitude EDMA").first?.value ?? ""
        XCTAssertTrue(r.contains("EDMA"),
                      "altitude output must reference the queried ICAO")
        XCTAssertTrue(r.contains("elev"),
                      "altitude output must include the field elevation, got: \(r)")
        // EDMA's published field elevation is 1516 ft. We derive from the
        // bundled runway data which should match within a few feet.
        XCTAssertTrue(r.range(of: #"elev 15\d{2} ft"#, options: .regularExpression) != nil,
                      "expected EDMA elevation in 1500–1599 ft range, got: \(r)")
    }

    func testAltitudeLineIsCaseInsensitive() throws {
        let engine = try NumiEngine()
        let lower = engine.evaluate("altitude edma").first?.value ?? ""
        let upper = engine.evaluate("ALTITUDE EDMA").first?.value ?? ""
        let abbrev = engine.evaluate("alt EDMA").first?.value ?? ""
        XCTAssertEqual(lower, upper,
                       "altitude pattern must accept lowercase + uppercase identically")
        XCTAssertEqual(abbrev, upper,
                       "alt and altitude must be interchangeable keywords")
    }

    func testAltitudeMultiStation() throws {
        let engine = try NumiEngine()
        let r = engine.evaluate("altitude EDMA EDDM").first?.value ?? ""
        XCTAssertTrue(r.contains("EDMA"), "multi-station output must include first ICAO")
        XCTAssertTrue(r.contains("EDDM"), "multi-station output must include second ICAO")
    }

    func testAltitudeUnknownAirport() throws {
        let engine = try NumiEngine()
        // ZZZZ has no runway data in the bundled CSV → no derivable elevation.
        let r = engine.evaluate("altitude ZZZZ").first?.value ?? ""
        XCTAssertTrue(r.localizedCaseInsensitiveContains("unknown") ||
                      r.localizedCaseInsensitiveContains("no runway"),
                      "altitude for an unknown ICAO should report missing data, got: \(r)")
    }

    func testBriefingLineRecognised() throws {
        let engine = try NumiEngine()
        let r = engine.evaluate("briefing EDMA").first?.value ?? ""
        XCTAssertFalse(r.isEmpty, "briefing line must produce output")
        // The block always contains the ALT section; METAR/TAF may be
        // 'Fetching…' placeholders until the network responds.
        XCTAssertTrue(r.contains("ALT EDMA"),
                      "briefing block must include the ALT section, got: \(r)")
    }

    func testBriefingAbbreviated() throws {
        let engine = try NumiEngine()
        // `brief` and `briefing` both work.
        let full   = engine.evaluate("briefing EDMA").first?.value ?? ""
        let short  = engine.evaluate("brief EDMA").first?.value ?? ""
        XCTAssertEqual(full, short,
                       "brief and briefing must produce equivalent output")
    }

    // MARK: - Stock quotes (live)
    //
    // The engine handler recognises STOCK / QUOTE / PRICE lines, kicks
    // a prefetch off the QuoteCacheBridge, and surfaces whatever is in
    // the cache right now (or a "Fetching…" placeholder). These tests
    // exercise the recognition path; they don't hit FMP.

    func testStockLineRecognised() throws {
        let engine = try NumiEngine()
        let r = engine.evaluate("stock AAPL").first?.value ?? ""
        XCTAssertFalse(r.isEmpty,
                       "stock line must produce some output (fetching placeholder is fine)")
        // Without a registered API-key provider, the bridge will record
        // a `missingAPIKey` error eventually — but in the synchronous
        // test path the bridge is asked before the async fetch errors,
        // so the placeholder is what's visible.
        XCTAssertTrue(r.contains("AAPL"),
                      "output must reference the symbol the user typed, got: \(r)")
    }

    func testStockLineIsCaseInsensitive() throws {
        let engine = try NumiEngine()
        let lower = engine.evaluate("stock aapl").first?.value ?? ""
        let upper = engine.evaluate("STOCK AAPL").first?.value ?? ""
        XCTAssertEqual(lower, upper,
                       "stock keyword must accept any case for both verb and symbol")
    }

    func testStockKeywordAliases() throws {
        // STOCK, QUOTE, PRICE all expand to the same handler.
        let engine = try NumiEngine()
        let stock = engine.evaluate("stock AAPL").first?.value ?? ""
        let quote = engine.evaluate("quote AAPL").first?.value ?? ""
        let price = engine.evaluate("price AAPL").first?.value ?? ""
        XCTAssertEqual(stock, quote, "stock/quote keywords must be equivalent")
        XCTAssertEqual(stock, price, "stock/price keywords must be equivalent")
    }

    func testStockMultiSymbol() throws {
        let engine = try NumiEngine()
        let r = engine.evaluate("stock AAPL MSFT").first?.value ?? ""
        XCTAssertTrue(r.contains("AAPL"), "multi-symbol output must include first symbol")
        XCTAssertTrue(r.contains("MSFT"), "multi-symbol output must include second symbol")
    }

    func testStockLineIgnoresMalformedSymbols() throws {
        // 6-letter token isn't a valid ticker shape (1–5 letters); the
        // line shouldn't match the stock pattern, so the engine falls
        // through to math evaluation and produces no stock-shaped
        // output for it.
        let engine = try NumiEngine()
        let result = engine.evaluate("stock TOOLONG").first?.value ?? ""
        XCTAssertFalse(result.contains("$"),
                       "6-letter token must not be treated as a ticker; got: \(result)")
    }

    @MainActor
    func testStockTypingDoesNotBurnAPICallsOnEachKeystroke() throws {
        // Simulate slow typing: each evaluate() represents one
        // keystroke landing after the calculator pane's 120 ms debounce.
        // Without per-evaluation transaction handling, this sequence
        // would queue four independent fetches (N, NV, NVD, NVDA);
        // with it, only NVDA survives as pending — every intermediate
        // symbol gets cancelled when the next evaluation removes it
        // from the requested set.
        let engine = try NumiEngine()
        let bridge = QuoteCacheBridge.shared
        bridge._reset()

        _ = engine.evaluate("stock N")
        XCTAssertEqual(bridge._pendingCount, 1, "first eval schedules 1 pending fetch")

        _ = engine.evaluate("stock NV")
        XCTAssertEqual(bridge._pendingCount, 1,
                       "second eval should cancel N and schedule NV — still 1 pending")

        _ = engine.evaluate("stock NVD")
        XCTAssertEqual(bridge._pendingCount, 1,
                       "third eval should cancel NV and schedule NVD — still 1 pending")

        _ = engine.evaluate("stock NVDA")
        XCTAssertEqual(bridge._pendingCount, 1,
                       "fourth eval should cancel NVD and schedule NVDA — still 1 pending")

        bridge._reset()
    }

    @MainActor
    func testStockLineRemovalCancelsPendingFetch() throws {
        // Typing `stock AAPL` then deleting the whole line before the
        // settle window elapses must cancel the pending fetch — there's
        // no symbol left in the document to fetch for.
        let engine = try NumiEngine()
        let bridge = QuoteCacheBridge.shared
        bridge._reset()

        _ = engine.evaluate("stock AAPL")
        XCTAssertEqual(bridge._pendingCount, 1)

        _ = engine.evaluate("2 + 2")
        XCTAssertEqual(bridge._pendingCount, 0,
                       "removing the stock line must cancel its pending fetch")

        bridge._reset()
    }

    // MARK: - User variables: case-insensitive
    //
    // The shared eval scope is wrapped in a Proxy that lowercases keys so
    // `Total_price` and `total_price` resolve to the same slot. The user's
    // identifier choice (camelCase / snake_case / MixedCase) is purely
    // cosmetic — math.js never sees a difference at the storage layer.

    func testVariableReferenceIsCaseInsensitive() throws {
        let engine = try NumiEngine()
        // Assign with one case, reference with another — they're the same var.
        let results = engine.evaluate("a = 5\nA")
        XCTAssertEqual(results.last?.value, "5",
                       "`A` after `a = 5` must resolve via the same scope slot")
    }

    func testSnakeCaseVariableSurvivesCaseShuffle() throws {
        let engine = try NumiEngine()
        let results = engine.evaluate("Total_price = 100\ntotal_price + 50")
        XCTAssertEqual(results.last?.value, "150",
                       "`total_price` must read the value written to `Total_price`")
    }

    func testReassignmentAcrossCasesOverwritesSameSlot() throws {
        // Two assignments with different cases should not produce two
        // separate variables — the second write wins.
        let engine = try NumiEngine()
        let results = engine.evaluate("ABC = 7\nabc = 42\nAbc")
        XCTAssertEqual(results.last?.value, "42",
                       "reassigning with a different case must overwrite the same slot")
    }

    func testNonCurrencyThreeLetterTokensAreNotUppercased() throws {
        // `the`, `and`, `for` are NOT currency codes — leaving them lowercase
        // matters because they'd otherwise become unbound symbols that mathjs
        // would reject. Comments are stripped, so this exercises the
        // identifier path: `5 the` is rewritten to `5 the` (unchanged) and
        // mathjs surfaces the resulting error normally.
        let engine = try NumiEngine()
        let preserved = engine.evaluate("100 fooblargl").first?.value ?? ""
        // The token isn't a known currency, so it must be passed through as
        // lowercase and surface as an "unknown unit" error rather than as a
        // silently-uppercased junk identifier.
        XCTAssertFalse(preserved.contains("FOOBLARGL"),
                       "non-currency tokens must not be uppercased")
    }

    // MARK: - Number formatting (thousands grouping + decimal padding)

    func testThousandsSeparatorGroupsByThree() throws {
        let engine = try NumiEngine()
        XCTAssertEqual(engine.evaluate("1000000").first?.value, "1 000 000")
        XCTAssertEqual(engine.evaluate("12345").first?.value, "12 345")
        XCTAssertEqual(engine.evaluate("999").first?.value, "999")    // no grouping below 4 digits
    }

    func testThousandsSeparatorPreservesDecimals() throws {
        let engine = try NumiEngine()
        let r = engine.evaluate("1234567.89").first
        XCTAssertEqual(r?.value, "1 234 567.89")
    }

    func testThousandsSeparatorWithUnits() throws {
        let engine = try NumiEngine()
        let r = engine.evaluate("10000 USD").first
        XCTAssertTrue((r?.value ?? "").contains("10 000"),
                      "expected 10 000 USD, got: \(r?.value ?? "")")
    }

    // MARK: - Loan / mortgage

    func testLoanFunctionDirect() throws {
        let engine = try NumiEngine()
        // 300 000 at 5.5% for 30 years → 1 703.37 / month
        let r = engine.evaluate("loan(300000, 5.5/100, 30)").first
        XCTAssertEqual(r?.kind, .expression)
        // Result is "1 703.37..." with thousands grouping; let's normalize.
        let normalised = (r?.value ?? "").replacingOccurrences(of: " ", with: "")
        let n = Double(normalised) ?? 0
        XCTAssertEqual(n, 1703.37, accuracy: 0.5)
    }

    func testLoanNaturalLanguage() throws {
        let engine = try NumiEngine()
        let r = engine.evaluate("loan 300k at 5.5% for 30 years").first
        XCTAssertEqual(r?.kind, .expression)
        let normalised = (r?.value ?? "").replacingOccurrences(of: " ", with: "")
        let n = Double(normalised) ?? 0
        XCTAssertEqual(n, 1703.37, accuracy: 0.5)
    }

    func testMortgageAlias() throws {
        let engine = try NumiEngine()
        let r = engine.evaluate("mortgage 450k at 6% for 30y").first
        XCTAssertEqual(r?.kind, .expression)
        let normalised = (r?.value ?? "").replacingOccurrences(of: " ", with: "")
        let n = Double(normalised) ?? 0
        XCTAssertEqual(n, 2697.98, accuracy: 1.0)
    }

    // MARK: - Compound interest

    func testCompoundFunctionDirect() throws {
        let engine = try NumiEngine()
        // 1000 at 7% for 10y, no contribution
        // monthly compounding: 1000 * (1 + 0.07/12)^120 ≈ 2009.66
        let r = engine.evaluate("compound(1000, 7/100, 10)").first
        XCTAssertEqual(r?.kind, .expression)
        let normalised = (r?.value ?? "").replacingOccurrences(of: " ", with: "")
        let n = Double(normalised) ?? 0
        XCTAssertEqual(n, 2009.66, accuracy: 1.0)
    }

    func testCompoundNaturalLanguage() throws {
        let engine = try NumiEngine()
        let r = engine.evaluate("compound 1000 at 7% for 10 years").first
        XCTAssertEqual(r?.kind, .expression)
    }

    func testCompoundWithMonthlyContribution() throws {
        let engine = try NumiEngine()
        // 500/month at 6% for 20 years with no initial
        // FV ≈ 231 020
        let r = engine.evaluate("500/month at 6% for 20 years").first
        XCTAssertEqual(r?.kind, .expression)
        let normalised = (r?.value ?? "").replacingOccurrences(of: " ", with: "")
        let n = Double(normalised) ?? 0
        XCTAssertEqual(n, 231020.45, accuracy: 100)
    }

    // MARK: - Tip / split

    func testTipPercentOnBill() throws {
        let engine = try NumiEngine()
        let r = engine.evaluate("20% tip on 86.50").first
        XCTAssertEqual(r?.kind, .expression)
        let n = Double((r?.value ?? "").replacingOccurrences(of: " ", with: "")) ?? 0
        XCTAssertEqual(n, 17.30, accuracy: 0.01)
    }

    func testSplitTwoArgs() throws {
        let engine = try NumiEngine()
        let r = engine.evaluate("145 split 4").first
        XCTAssertEqual(r?.kind, .expression)
        let n = Double((r?.value ?? "").replacingOccurrences(of: " ", with: "")) ?? 0
        XCTAssertEqual(n, 36.25, accuracy: 0.01)
    }

    func testTipAndSplitTogether() throws {
        // 145 + 18% tip = 171.10. /4 people = 42.78
        let engine = try NumiEngine()
        let r = engine.evaluate("145 + 18% tip split 4").first
        XCTAssertEqual(r?.kind, .expression)
        let n = Double((r?.value ?? "").replacingOccurrences(of: " ", with: "")) ?? 0
        XCTAssertEqual(n, 42.78, accuracy: 0.02)
    }

    // MARK: - Date math

    func testDaysBetweenIsoDates() throws {
        let engine = try NumiEngine()
        let r = engine.evaluate("days between 2024-01-01 and 2024-12-31").first
        XCTAssertEqual(r?.value, "365")
    }

    func testDaysUntilFutureDate() throws {
        let engine = try NumiEngine()
        // Far-future date; just assert that we get a sensible positive number,
        // not an error.
        let r = engine.evaluate("days until 2099-12-31").first
        XCTAssertEqual(r?.kind, .expression)
        let n = Double((r?.value ?? "").replacingOccurrences(of: " ", with: "")) ?? 0
        XCTAssertGreaterThan(n, 10_000)
    }

    func testAgeFromBirthDate() throws {
        let engine = try NumiEngine()
        // Born 1990 → at least 35 in 2025+ (test running in 2026 per memory)
        let r = engine.evaluate("age 1990-03-15").first
        XCTAssertEqual(r?.kind, .expression)
        let n = Int(r?.value ?? "") ?? 0
        XCTAssertGreaterThanOrEqual(n, 35)
        XCTAssertLessThan(n, 60)
    }

    // MARK: - Feet & inches arithmetic

    func testFeetInchesAddition() throws {
        let engine = try NumiEngine()
        let r = engine.evaluate("12'6\" + 8'3\"").first
        XCTAssertEqual(r?.kind, .expression)
        // 12'6" + 8'3" = 20'9"
        XCTAssertEqual(r?.value, "20'9\"")
    }

    func testFeetInchesSubtraction() throws {
        let engine = try NumiEngine()
        let r = engine.evaluate("12'6\" - 5'0\"").first
        XCTAssertEqual(r?.kind, .expression)
        XCTAssertEqual(r?.value, "7'6\"")
    }

    func testFeetInchesConvertToMm() throws {
        // No feet-inches notation in target unit → result is in mm, not ftin.
        let engine = try NumiEngine()
        let r = engine.evaluate("12'6\" in mm").first
        XCTAssertEqual(r?.kind, .expression)
        // 12'6" = 150" = 3810 mm
        let normalised = (r?.value ?? "").replacingOccurrences(of: " ", with: "")
        XCTAssertTrue(normalised.contains("3810") || normalised.contains("3 810"),
                      "expected 3 810 mm, got: \(r?.value ?? "")")
    }

    // MARK: - Drawing scale

    func testScaleRealToDrawing() throws {
        let engine = try NumiEngine()
        // 4500 mm at 1:50 → 90 mm
        let r = engine.evaluate("4500 mm at 1:50").first
        XCTAssertEqual(r?.kind, .expression)
        XCTAssertTrue((r?.value ?? "").contains("90"),
                      "expected 90 mm, got: \(r?.value ?? "")")
    }

    func testScaleDrawingToReal() throws {
        let engine = try NumiEngine()
        // 24 mm on drawing at 1:100 → 2400 mm
        let r = engine.evaluate("24 mm on drawing at 1:100").first
        XCTAssertEqual(r?.kind, .expression)
        let normalised = (r?.value ?? "").replacingOccurrences(of: " ", with: "")
        XCTAssertTrue(normalised.contains("2400") || normalised.contains("2 400"),
                      "expected 2 400 mm, got: \(r?.value ?? "")")
    }

    // MARK: - Material take-off

    func testConcreteVolume() throws {
        let engine = try NumiEngine()
        // 6 x 4 x 0.15 = 3.6 m³
        let r = engine.evaluate("concrete 6 m x 4 m x 0.15 m").first
        XCTAssertEqual(r?.kind, .expression)
        XCTAssertTrue((r?.value ?? "").contains("3.6"),
                      "expected 3.6 m³, got: \(r?.value ?? "")")
    }

    func testTilesNeededForRoom() throws {
        let engine = try NumiEngine()
        // 25 m² area, 30 x 30 cm tiles = 0.09 m²/tile → 278 tiles
        let r = engine.evaluate("tiles for 25 m^2 at 30 x 30 cm").first
        XCTAssertEqual(r?.kind, .expression)
        let normalised = (r?.value ?? "").replacingOccurrences(of: " ", with: "")
        XCTAssertTrue(normalised.contains("278"),
                      "expected 278 tiles, got: \(r?.value ?? "")")
    }

    // MARK: - Stair calculator (raw JS function)

    func testStairsDirect() throws {
        let engine = try NumiEngine()
        // 2.8 m rise over 4 m run, max riser 180 mm
        // → ~17 risers, 16 treads, riser ~165 mm, tread 250 mm
        // The JS returns an object; mathjs formats it. Just verify no error
        // and the result mentions "risers" or has expected numbers.
        let r = engine.evaluate("stairs(2.8 m, 4 m, 180 mm)").first
        XCTAssertEqual(r?.kind, .expression)
        let v = r?.value ?? ""
        XCTAssertTrue(v.contains("17") || v.contains("16"),
                      "expected stairs result to contain riser/tread count, got: \(v)")
    }

    // MARK: - Documented math functions
    //
    // Every (input, expected-substring) pair below mirrors an example or
    // table entry in DocumentationView's "Functions" section. The test
    // runs all of them and reports the full set of failures in a single
    // assertion so one regression doesn't mask the others.
    func testDocumentedMathFunctions() throws {
        let engine = try NumiEngine()
        let cases: [(expr: String, expect: String)] = [
            ("sqrt(16)",         "4"),
            ("cbrt(27)",         "3"),
            ("nthRoot(81, 4)",   "3"),
            ("abs(-7)",          "7"),
            ("ln(3)",            "1.0986"),
            ("ln(e)",            "1"),
            ("log(1000)",        "3"),     // base-10 per docs
            ("log(8, 2)",        "3"),
            ("5!",               "120"),
            ("round(2.6)",       "3"),
            ("ceil(2.1)",        "3"),
            ("floor(2.9)",       "2"),
            ("sin(0)",           "0"),
            ("cos(0)",           "1"),
            ("tan(0)",           "0"),
            ("sin(45 deg)",      "0.707"),
            ("asin(1)",          "1.5707"),
            ("acos(1)",          "0"),
            ("atan(1)",          "0.7853"),
            ("sinh(0)",          "0"),
            ("cosh(0)",          "1"),
            ("tanh(0)",          "0"),
            ("min(3, 1, 2)",     "1"),
            ("max(3, 1, 2)",     "3"),
            ("mean(2, 4, 6)",    "4"),
            ("median(1, 2, 3)",  "2"),
        ]
        var failures: [String] = []
        for (expr, expect) in cases {
            let value = engine.evaluate(expr).first?.value ?? "<nil>"
            if !value.contains(expect) {
                failures.append("`\(expr)` → got \"\(value)\", expected substring \"\(expect)\"")
            }
        }
        XCTAssertTrue(failures.isEmpty,
                      "Documented function failures:\n" + failures.joined(separator: "\n"))
    }

    // Sweep over every unit listed in DocumentationView's "Units" section.
    // Each case converts `1 X in Y` and verifies the result looks sane
    // (non-empty, no "Undefined" / "Error" sentinel). Reports all failures
    // in one pass.
    func testDocumentedUnits() throws {
        let engine = try NumiEngine()
        // (expression, expected substring) — substring kept loose so
        // formatting drift (1.5 m vs 1.5 meter) doesn't fail the test.
        let cases: [(String, String)] = [
            // Length
            ("1 km in m",       "1000"),
            ("100 cm in m",     "1"),
            ("1000 mm in m",    "1"),
            ("1 in in cm",      "2.54"),
            ("1 ft in cm",      "30.48"),
            ("1 yd in m",       "0.9144"),
            ("1 mi in km",      "1.609"),
            ("1 NM in km",      "1.852"),
            ("1 parsec in ly",  "3.26"),
            ("1 AU in km",      "149597"),
            ("1 fathom in m",   "1.8288"),
            ("1 furlong in m",  "201"),
            // Mass
            ("1 kg in g",       "1000"),
            ("1 mg in g",       "0.001"),
            ("1 oz in g",       "28.3"),
            ("1 lb in kg",      "0.45"),
            ("1 ton in kg",     "907"),       // US short ton
            ("1 stone in kg",   "6.35"),
            ("1 ct in g",       "0.2"),
            // Volume
            ("1 L in mL",       "1000"),
            ("1 dL in mL",      "100"),
            ("1 gallon in L",   "3.78"),
            ("1 igallon in L",  "4.54"),
            ("1 pint in mL",    "473"),
            ("1 quart in L",    "0.94"),
            ("1 cup in mL",     "236"),
            // math.js uses the US-customary rounded definitions
            // (tablespoon = 15 mL, teaspoon = 5 mL), not the metric ones.
            ("1 tbsp in mL",    "15"),
            ("1 tsp in mL",     "5"),
            // Time
            ("60 s in min",     "1"),
            ("1 h in min",      "60"),
            ("1 day in h",      "24"),
            ("1 week in day",   "7"),
            ("1 year in day",   "365"),
            // Temperature
            ("0 degC in K",     "273"),
            ("32 degF in degC", "0"),
            // Pressure
            ("1 kPa in Pa",     "1000"),
            ("1 hPa in Pa",     "100"),
            ("1 bar in Pa",     "100000"),
            ("1 mbar in Pa",    "100"),
            ("1 atm in Pa",     "101325"),
            ("1 psi in Pa",     "6894"),
            ("1 inHg in Pa",    "3386"),
            ("1 mmHg in Pa",    "133"),
            ("1 torr in Pa",    "133"),
            // Speed
            ("1 m/s in km/h",   "3.6"),
            ("100 km/h in mph", "62.13"),
            ("100 kmh in mph",  "62.13"),
            ("100 kph in mph",  "62.13"),
            ("100 mph in km/h", "160.9"),
            ("1 kt in km/h",    "1.85"),
            ("1 kts in km/h",   "1.85"),
            ("1 kn in km/h",    "1.85"),
            // Force
            // math.js stores dyne as 1e-5 N, so the round-trip yields
            // 99 999.99…  rather than a clean 100 000. Accept either.
            ("1 N in dyne",     "99999"),
            ("1 lbf in N",      "4.44"),
            ("1 kp in N",       "9.80"),
            ("1 kgf in N",      "9.80"),
            // Energy
            ("1 kJ in J",       "1000"),
            ("1 MJ in J",       "1000000"),
            ("1 BTU in J",      "1055"),
            ("1 Wh in J",       "3600"),
            ("1 kWh in J",      "3600000"),
            ("1 MWh in J",      "3600000000"),
            ("1 GWh in J",      "3600000000000"),
            ("1 cal in J",      "4.184"),
            ("1 Cal in J",      "4184"),
            // Power
            ("1 kW in W",       "1000"),
            ("1 MW in W",       "1000000"),
            ("1 hp in W",       "745"),
            ("1 ps in W",       "735"),
            // Frequency
            ("1 kHz in Hz",     "1000"),
            ("1 MHz in Hz",     "1000000"),
            ("1 GHz in Hz",     "1000000000"),
            ("60 rpm in Hz",    "1"),
            // Data
            ("1 byte in bit",   "8"),
            ("1 KB in byte",    "1000"),
            ("1 MB in byte",    "1000000"),
            ("1 GB in byte",    "1000000000"),
            ("1 KiB in byte",   "1024"),
            ("1 MiB in byte",   "1048576"),
            ("1 GiB in byte",   "1073741824"),
            ("8 kbps in bit/s", "8000"),
            ("1 Mbps in kbps",  "1000"),
            ("1 Gbps in Mbps",  "1000"),
            // Angle
            ("180 deg in rad",  "3.14"),
            ("1 rad in deg",    "57.2"),
            ("1 grad in deg",   "0.9"),
            ("60 arcmin in deg","1"),
            ("3600 arcsec in deg","1"),
        ]
        // Normalise the engine's display formatting so we compare numeric
        // content, not cosmetic separators:
        //  - strip the thin-space U+202F and U+00A0 used as thousand groups
        //  - collapse runs of whitespace
        func normalise(_ s: String) -> String {
            var out = s
            out = out.replacingOccurrences(of: "\u{202F}", with: "")
            out = out.replacingOccurrences(of: "\u{00A0}", with: "")
            out = out.replacingOccurrences(of: " ", with: "")
            return out
        }
        var failures: [String] = []
        for (expr, expect) in cases {
            let raw = engine.evaluate(expr).first?.value ?? "<nil>"
            let value = normalise(raw)
            let needle = normalise(expect)
            // A successful evaluation never returns "Undefined" or "Error" sentinels.
            if raw.lowercased().contains("undefined")
                || raw.lowercased().contains("error")
                || raw.lowercased().contains("unknown unit")
                || raw.lowercased().contains("resolving")
                || raw == "<nil>"
                || !value.contains(needle) {
                failures.append("`\(expr)` → got \"\(raw)\", expected substring \"\(expect)\"")
            }
        }
        XCTAssertTrue(failures.isEmpty,
                      "Documented unit failures:\n" + failures.joined(separator: "\n"))
    }

}
