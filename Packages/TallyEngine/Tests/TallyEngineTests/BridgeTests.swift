import XCTest
@testable import TallyEngine

@MainActor
final class BridgeTests: XCTestCase {

    // MARK: - TimezoneBridge

    func testTimezoneAliasUSA() {
        XCTAssertEqual(TimezoneBridge.resolve("PST")?.identifier, "America/Los_Angeles")
        XCTAssertEqual(TimezoneBridge.resolve("EST")?.identifier, "America/New_York")
        XCTAssertEqual(TimezoneBridge.resolve("New York")?.identifier, "America/New_York")
    }

    func testTimezoneAliasEurope() {
        XCTAssertEqual(TimezoneBridge.resolve("Berlin")?.identifier, "Europe/Berlin")
        XCTAssertEqual(TimezoneBridge.resolve("London")?.identifier, "Europe/London")
    }

    func testTimezoneAliasAsia() {
        XCTAssertEqual(TimezoneBridge.resolve("HKT")?.identifier, "Asia/Hong_Kong")
        XCTAssertEqual(TimezoneBridge.resolve("Tokyo")?.identifier, "Asia/Tokyo")
    }

    func testEngineTimezoneNow() throws {
        let engine = try NumiEngine()
        let results = engine.evaluate("Berlin time")
        XCTAssertEqual(results.first?.kind, .timezone)
        XCTAssertNotNil(results.first?.value)
        XCTAssertTrue(results.first?.value?.contains("CET") == true
                      || results.first?.value?.contains("CEST") == true
                      || results.first?.value?.contains("GMT") == true)
    }

    func testEngineTimezoneConvert() throws {
        let engine = try NumiEngine()
        let results = engine.evaluate("2:30 pm HKT in Berlin")
        XCTAssertEqual(results.first?.kind, .timezone)
        XCTAssertNotNil(results.first?.value)
    }

    /// Regression: `Zulu` (= UTC) must always win over any cached
    /// CLGeocoder fuzzy-match. Before the fix, the geocoder mapped
    /// "Zulu" to "Zulia, Venezuela" (America/Caracas, GMT-4) and the
    /// false hit poisoned the on-disk cache permanently — so
    /// `2000 Munich time in Zulu` rendered "14:00 GMT-4" instead of
    /// "18:00 GMT". Two layers guard the alias now: `resolveSync`
    /// checks the static table first, and `CityResolver.resolve`
    /// refuses to send known aliases to CLGeocoder.
    func testZuluAlwaysResolvesToUTC() async throws {
        let bridge = TimezoneBridge()

        // Sync path: alias wins immediately.
        XCTAssertEqual(bridge.resolveSync("Zulu")?.timezoneId, "GMT")
        XCTAssertEqual(bridge.resolveSync("ZULU")?.timezoneId, "GMT")
        XCTAssertEqual(bridge.resolveSync("Z")?.timezoneId, "GMT")

        // Async path: must NOT send Zulu to CLGeocoder, so the cache
        // never picks up Zulia. A nil return is the correct signal —
        // the sync resolver already handles the value.
        let attempted = await CityResolver.shared.resolve(query: "Zulu")
        XCTAssertNil(attempted, "CLGeocoder must not be queried for known aliases")
        XCTAssertNil(CityResolver.shared.cached(for: "Zulu"),
                     "cache must stay clean of alias entries")

        // End-to-end: even after the (rejected) poisoning attempt,
        // the conversion still produces the right UTC result.
        let out = bridge.convertTimeString("2000", from: "Munich time", to: "Zulu")
        XCTAssertEqual(out?.formatted.prefix(5), "18:00")
    }

    // MARK: - Aviation bridge through math.js

    func testAviationBridgeDensityAltitude() throws {
        let engine = try NumiEngine()
        // Hot day at field elevation 0: DA ≈ 1800 ft per FAA approximation.
        // Output is formatted "1 800" with a thousands space — strip before
        // parsing as a Double.
        let results = engine.evaluate("density_altitude(0, 30, 29.92)")
        let raw = (results.first?.value ?? "").replacingOccurrences(of: " ", with: "")
        let v = Double(raw) ?? 0
        XCTAssertEqual(v, 1800, accuracy: 5)
    }

    func testAviationBridgeCrosswind() throws {
        let engine = try NumiEngine()
        // Runway 27 (270°), wind 300@10 → crosswind = 10·sin(30°) = 5
        let results = engine.evaluate("crosswind(270, 300, 10)")
        let v = Double(results.first?.value ?? "") ?? 0
        XCTAssertEqual(v, 5, accuracy: 0.001)
    }

    func testAviationBridgeGroundSpeed() throws {
        let engine = try NumiEngine()
        // course 360, TAS 100, wind 360@20 → GS 80
        let results = engine.evaluate("ground_speed(360, 100, 360, 20)")
        let v = Double(results.first?.value ?? "") ?? 0
        XCTAssertEqual(v, 80, accuracy: 0.001)
    }

    // MARK: - FX bridge: apply a known snapshot, then convert

    func testFXBridgeConversion() throws {
        let engine = try NumiEngine()
        // 1 USD = 0.9 EUR (snapshot) → 100 EUR = 1/0.9 × 100 = 111.11 USD
        let snapshot = FXService.Snapshot(
            base: "USD",
            ratesPerUSD: ["USD": 1.0, "EUR": 0.9, "GBP": 0.8],
            timestamp: Date()
        )
        engine.applyFX(snapshot)

        let results = engine.evaluate("100 EUR to USD")
        let value = results.first?.value ?? ""
        XCTAssertTrue(value.contains("USD"))
        let numeric = value.split(separator: " ").first.flatMap { Double($0) } ?? 0
        XCTAssertEqual(numeric, 100.0 / 0.9, accuracy: 0.01)
    }

    func testFXBridgeLowercaseCurrencyCode() throws {
        let engine = try NumiEngine()
        let snapshot = FXService.Snapshot(
            base: "USD",
            ratesPerUSD: ["USD": 1.0, "EUR": 0.9],
            timestamp: Date()
        )
        engine.applyFX(snapshot)
        let results = engine.evaluate("100 eur in usd")
        XCTAssertEqual(results.first?.kind, .expression)
        let value = results.first?.value ?? ""
        XCTAssertTrue(value.contains("USD") || value.contains("usd"),
                      "got: \(value)")
    }

    // MARK: - Airport code resolution

    func testAirportIATACode() {
        let r = TimezoneBridge.resolve("MUC")
        XCTAssertEqual(r?.identifier, "Europe/Berlin")
    }

    func testAirportICAOCode() {
        let r = TimezoneBridge.resolve("EDDM")
        XCTAssertEqual(r?.identifier, "Europe/Berlin")
    }

    func testCityResolverHintsCanonicalName() {
        let cached = CityResolver.shared.cached(for: "MUC")
        XCTAssertEqual(cached?.canonicalName, "Munich")
        XCTAssertEqual(cached?.originalCode, "MUC")
    }

    func testBaliCityNamesResolve() {
        // Bali villages are in our static fast-path, no geocoder needed.
        XCTAssertEqual(TimezoneBridge.resolve("Canggu")?.identifier, "Asia/Makassar")
        XCTAssertEqual(TimezoneBridge.resolve("Ubud")?.identifier,   "Asia/Makassar")
        XCTAssertEqual(TimezoneBridge.resolve("Seminyak")?.identifier, "Asia/Makassar")
    }

    func testEngineConversionWithAirportCode() throws {
        let engine = try NumiEngine()
        let results = engine.evaluate("2:30 pm HKT in MUC")
        XCTAssertEqual(results.first?.kind, .timezone)
        XCTAssertTrue(results.first?.value?.contains("(Munich)") == true,
                      "expected '(Munich)' hint, got: \(results.first?.value ?? "nil")")
    }

    func testEngineConversionBerlinToCanggu() throws {
        let engine = try NumiEngine()
        let results = engine.evaluate("14:30 Berlin in Canggu")
        XCTAssertEqual(results.first?.kind, .timezone)
        XCTAssertNotNil(results.first?.value)
    }

    func testInvalidExpressionShowsError() throws {
        let engine = try NumiEngine()
        // Unknown unit should produce a visible error.
        let results = engine.evaluate("100 fooblargl")
        XCTAssertEqual(results.first?.kind, .error)
        XCTAssertNotNil(results.first?.value)
        XCTAssertFalse((results.first?.value ?? "").isEmpty)
    }

    // MARK: - MetarCacheBridge

    func testMetarCacheBridgeEnforcesMaxEntries() {
        let bridge = MetarCacheBridge()
        // Insert more than the cap; oldest-by-lastUsed get evicted.
        for i in 0..<(MetarCacheBridge.maxEntries + 10) {
            bridge._testInsert(
                kind: .metar,
                icao: String(format: "K%03d", i),
                lastUsed: Date(timeIntervalSinceNow: TimeInterval(i))
            )
        }
        XCTAssertEqual(bridge.entryCount, MetarCacheBridge.maxEntries,
                       "bridge should evict back to max-entries after burst insert")
    }

    func testMetarCacheBridgeCachedBumpsLastUsed() {
        let bridge = MetarCacheBridge()
        // Insert with an old lastUsed; reading via `cached` should refresh it.
        let staleTime = Date(timeIntervalSinceNow: -3600)
        bridge._testInsert(kind: .metar, icao: "EDDM", lastUsed: staleTime)
        XCTAssertEqual(bridge._testLastUsed(kind: .metar, icao: "EDDM"), staleTime)
        _ = bridge.cached(kind: .metar, icao: "EDDM")
        let bumped = bridge._testLastUsed(kind: .metar, icao: "EDDM")
        XCTAssertNotNil(bumped)
        XCTAssertGreaterThan(bumped!, staleTime,
                             "cached() read should bump lastUsed to now")
    }

    func testMetarCacheBridgeEvictIdleDropsOldEntries() {
        let bridge = MetarCacheBridge()
        // Two entries: one used 2h ago (idle), one used now (active).
        bridge._testInsert(kind: .metar, icao: "OLDD",
                           lastUsed: Date(timeIntervalSinceNow: -2 * 3600))
        bridge._testInsert(kind: .metar, icao: "NEWW", lastUsed: Date())
        XCTAssertEqual(bridge.entryCount, 2)
        bridge.evictIdle()
        XCTAssertNil(bridge.cached(kind: .metar, icao: "OLDD"),
                     "idle entry should be evicted")
        XCTAssertNotNil(bridge.cached(kind: .metar, icao: "NEWW"),
                        "active entry should survive")
    }

    func testMetarCacheBridgeActiveStationsExcludesIdle() {
        let bridge = MetarCacheBridge()
        bridge._testInsert(kind: .metar, icao: "OLDD",
                           lastUsed: Date(timeIntervalSinceNow: -2 * 3600))
        bridge._testInsert(kind: .taf,   icao: "NEWW", lastUsed: Date())
        let stations = bridge.activeStations()
        XCTAssertEqual(stations.count, 1)
        XCTAssertEqual(stations.first?.0, .taf)
        XCTAssertEqual(stations.first?.1.uppercased(), "NEWW")
    }

    // MARK: - AirportCodeMap (IATA ↔ ICAO)

    func testAirportCodeMapResolvesIATAToICAO() {
        XCTAssertEqual(AirportCodeMap.icao(forIATA: "JFK"), "KJFK")
        XCTAssertEqual(AirportCodeMap.icao(forIATA: "MUC"), "EDDM")
        XCTAssertEqual(AirportCodeMap.icao(forIATA: "HND"), "RJTT")
    }

    func testAirportCodeMapCaseInsensitiveIATA() {
        // Users type lowercase / mixed-case casually.
        XCTAssertEqual(AirportCodeMap.icao(forIATA: "jfk"), "KJFK")
        XCTAssertEqual(AirportCodeMap.icao(forIATA: "Jfk"), "KJFK")
    }

    func testAirportCodeMapReverseLookup() {
        XCTAssertEqual(AirportCodeMap.iata(forICAO: "KJFK"), "JFK")
        XCTAssertEqual(AirportCodeMap.iata(forICAO: "EDDM"), "MUC")
    }

    func testAirportCodeMapUnknownIATAReturnsNil() {
        XCTAssertNil(AirportCodeMap.icao(forIATA: "ZZZ"))
    }

    func testAirportCodeMapCanonicalICAOFromFourLetter() {
        // Valid 4-letter codes pass through unchanged.
        XCTAssertEqual(AirportCodeMap.canonicalICAO(from: "KJFK"), "KJFK")
        XCTAssertEqual(AirportCodeMap.canonicalICAO(from: "eddm"), "EDDM")
    }

    func testAirportCodeMapCanonicalICAOFromThreeLetterIATA() {
        XCTAssertEqual(AirportCodeMap.canonicalICAO(from: "JFK"), "KJFK")
        XCTAssertEqual(AirportCodeMap.canonicalICAO(from: "muc"), "EDDM")
    }

    func testAirportCodeMapCanonicalICAOStripsJunk() {
        // Non-alphanumeric input gets stripped before lookup.
        XCTAssertEqual(AirportCodeMap.canonicalICAO(from: "K-JFK"), "KJFK")
        XCTAssertEqual(AirportCodeMap.canonicalICAO(from: " JFK "), "KJFK")
    }

    func testAirportCodeMapCanonicalICAORejectsTooShortOrLong() {
        XCTAssertNil(AirportCodeMap.canonicalICAO(from: "JF"))
        XCTAssertNil(AirportCodeMap.canonicalICAO(from: "TOOLONG"))
        XCTAssertNil(AirportCodeMap.canonicalICAO(from: ""))
    }

    // MARK: - MetarService.sanitise + IATA

    func testMetarServiceSanitiseResolvesIATA() {
        XCTAssertEqual(MetarService.sanitise(icao: "JFK"), "KJFK")
        XCTAssertEqual(MetarService.sanitise(icao: "muc"), "EDDM")
    }

    func testMetarServiceSanitisePassesValidICAO() {
        XCTAssertEqual(MetarService.sanitise(icao: "KJFK"), "KJFK")
        XCTAssertEqual(MetarService.sanitise(icao: "eddm"), "EDDM")
    }

    func testMetarServiceSanitiseRejectsUnknownIATA() {
        // Three letters, not a known IATA → empty (caller fails fast).
        XCTAssertEqual(MetarService.sanitise(icao: "ZZZ"), "")
    }

    // MARK: - MetarCacheBridge canonicalises before keying

    func testMetarCacheBridgeIATAAndICAOShareEntry() {
        let bridge = MetarCacheBridge()
        bridge._testInsert(kind: .metar, icao: "KJFK")
        // Look up via the 3-letter IATA; the bridge canonicalises and
        // should hit the same entry.
        XCTAssertNotNil(bridge.cached(kind: .metar, icao: "JFK"),
                        "JFK and KJFK must resolve to the same cache entry")
        // And vice-versa.
        bridge._testInsert(kind: .taf, icao: "EDDM")
        XCTAssertNotNil(bridge.cached(kind: .taf, icao: "MUC"),
                        "MUC and EDDM must resolve to the same cache entry")
    }
}
