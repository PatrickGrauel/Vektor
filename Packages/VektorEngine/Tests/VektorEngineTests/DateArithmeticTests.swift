import XCTest
@testable import VektorEngine

@MainActor
final class DateArithmeticTests: XCTestCase {
    func testReportedTodayPlusTwoWeeks() throws {
        let calendar = gregorianCalendar(in: "Asia/Makassar")
        let now = date(2026, 10, 11, hour: 13, calendar: calendar)
        XCTAssertEqual(NumiEngine.handleDateKeywordLine("today + 2 weeks", now: now, calendar: calendar),
                       "Sun, 25 Oct 2026")

        let engine = try NumiEngine()
        let results = engine.evaluate("today\ntoday + 2 weeks")
        let formatter = dateFormatter(calendar: Calendar(identifier: .gregorian))
        let today = try XCTUnwrap(formatter.date(from: try XCTUnwrap(results[0].value)))
        let expected = try XCTUnwrap(formatter.calendar.date(byAdding: .day, value: 14, to: today))
        XCTAssertEqual(results[1].kind, .expression)
        XCTAssertEqual(results[1].value, formatter.string(from: expected))
    }

    func testRelativeKeywordsAndWholeCalendarUnits() {
        let calendar = gregorianCalendar(in: "Asia/Makassar")
        let now = date(2026, 10, 11, hour: 13, calendar: calendar)
        let examples = [
            ("today + 1 day", "Mon, 12 Oct 2026"),
            ("tomorrow - 1 day", "Sun, 11 Oct 2026"),
            ("yesterday + 1 day", "Sun, 11 Oct 2026"),
            ("today + 0 days", "Sun, 11 Oct 2026"),
            ("today - 1 week", "Sun, 4 Oct 2026"),
            ("today + 2 months", "Fri, 11 Dec 2026"),
            ("today + 1 year", "Mon, 11 Oct 2027"),
            ("  TODAY + 2 WEEKS  ", "Sun, 25 Oct 2026"),
        ]
        for (source, expected) in examples {
            XCTAssertEqual(NumiEngine.handleDateKeywordLine(source, now: now, calendar: calendar),
                           expected, source)
        }
    }

    func testIsoDatesSupportAdditionAndSubtractionThroughEngine() throws {
        let engine = try NumiEngine()
        let examples = [
            ("2026-01-01 + 2 weeks", "Thu, 15 Jan 2026"),
            ("2026-01-01 - 2 weeks", "Thu, 18 Dec 2025"),
            ("2026-12-31 + 1 day", "Fri, 1 Jan 2027"),
            ("2026-10-11 + 2 years", "Wed, 11 Oct 2028"),
        ]
        for (source, expected) in examples {
            let result = engine.evaluate(source).first
            XCTAssertEqual(result?.kind, .expression, source)
            XCTAssertEqual(result?.value, expected, source)
        }
    }

    func testMonthEndsAndLeapYearsUseCalendarArithmetic() {
        let calendar = gregorianCalendar(in: "UTC")
        let examples = [
            ("2024-01-31 + 1 month", "Thu, 29 Feb 2024"),
            ("2024-03-31 - 1 month", "Thu, 29 Feb 2024"),
            ("2023-01-31 + 1 month", "Tue, 28 Feb 2023"),
            ("2024-02-29 + 1 year", "Fri, 28 Feb 2025"),
            ("2024-02-29 - 1 year", "Tue, 28 Feb 2023"),
            ("2024-03-01 - 1 day", "Thu, 29 Feb 2024"),
        ]
        for (source, expected) in examples {
            XCTAssertEqual(NumiEngine.handleDateKeywordLine(source, calendar: calendar),
                           expected, source)
        }
    }

    func testDayArithmeticCrossesDaylightSavingChanges() {
        let calendar = gregorianCalendar(in: "America/Los_Angeles")
        // These transitions contain a 23-hour or 25-hour day. Adding a
        // fixed number of seconds would land on the wrong calendar date.
        let examples = [
            ("2026-03-09 - 1 day", "Sun, 8 Mar 2026"),
            ("2026-11-01 + 1 day", "Mon, 2 Nov 2026"),
            ("2026-03-02 + 1 week", "Mon, 9 Mar 2026"),
            ("2026-10-26 + 1 week", "Mon, 2 Nov 2026"),
        ]
        for (source, expected) in examples {
            XCTAssertEqual(NumiEngine.handleDateKeywordLine(source, calendar: calendar),
                           expected, source)
        }

        let now = date(2026, 11, 1, hour: 12, calendar: calendar)
        XCTAssertEqual(NumiEngine.handleDateKeywordLine("today + 1 day", now: now, calendar: calendar),
                       "Mon, 2 Nov 2026")
    }

    func testIsoDatesAreResolvedInLocalTimezoneWestOfUTC() {
        let calendar = gregorianCalendar(in: "America/Los_Angeles")
        XCTAssertEqual(NumiEngine.handleDateKeywordLine("2026-03-01 + 0 days", calendar: calendar),
                       "Sun, 1 Mar 2026")
        XCTAssertEqual(NumiEngine.handleDateKeywordLine("2026-03-01 + 1 day", calendar: calendar),
                       "Mon, 2 Mar 2026")
        XCTAssertEqual(NumiEngine.handleDateKeywordLine("weekday 2026-03-01", calendar: calendar),
                       "Sunday")
    }

    func testLabelsAndInlineCommentsKeepDateArithmetic() throws {
        let engine = try NumiEngine()
        for source in [
            "Vacation: 2026-01-01 + 2 weeks",
            "2026-01-01 + 2 weeks // departure",
            "Vacation: 2026-01-01 + 2 weeks // departure",
            "Vacation: 2026-01-01 + 2 weeks \"departure\"",
        ] {
            let result = engine.evaluate(source).first
            XCTAssertEqual(result?.kind, .expression, source)
            XCTAssertEqual(result?.value, "Thu, 15 Jan 2026", source)
        }
    }

    func testMalformedAndUnsupportedDateArithmeticIsNotAccepted() throws {
        let engine = try NumiEngine()
        for source in [
            "today + 1.5 days",
            "today + 2 hours",
            "today + 2 weekz",
            "today + days",
            "today +",
            "today - -1 day",
            "today + 2 weeks trailing",
            "today + 999999999999999999999999999999 days",
            "today + \(Int.max) days",
            "2026-01-01 + 1.5 days",
            "2026-01-01 + 2 hours",
            "2026-02-30 + 1 day",
            "2025-02-29 + 1 day",
            "2026-13-01 + 1 day",
            "2026-01-00 + 1 day",
            "0001-01-01 - 1 day",
            "9999-12-31 + 1 day",
        ] {
            XCTAssertNil(NumiEngine.handleDateKeywordLine(source), source)
            XCTAssertEqual(engine.evaluate(source).first?.kind, .error, source)
        }
    }

    func testDateResultsDoNotPolluteSumOrPrev() throws {
        let engine = try NumiEngine()
        let results = engine.evaluate("5\n2026-01-01 + 2 weeks\n10\nsum\nprev")
        XCTAssertEqual(results[1].value, "Thu, 15 Jan 2026")
        XCTAssertEqual(results[3].value, "15")
        XCTAssertEqual(results[4].value, "15")
    }

    private func gregorianCalendar(in timezone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone)!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0,
                      calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func dateFormatter(calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEE, d MMM yyyy"
        return formatter
    }
}
