import XCTest
@testable import VektorEngine

final class DigitGroupingTests: XCTestCase {
    /// Render the gaps as spaces so expectations read naturally.
    private func grouped(_ s: String) -> String {
        let gaps = Set(DigitGrouping.gapPositions(in: s))
        var out = ""
        for (i, u) in Array(s.utf16).enumerated() {
            out += String(utf16CodeUnits: [u], count: 1)
            if gaps.contains(i) { out += " " }
        }
        return out
    }

    func testGroupsLargeIntegers() {
        XCTAssertEqual(grouped("22111555.11"), "22 111 555.11")
        XCTAssertEqual(grouped("12000"), "12 000")
        XCTAssertEqual(grouped("123456"), "123 456")
        XCTAssertEqual(grouped("1234567 EUR in USD"), "1 234 567 EUR in USD")
        XCTAssertEqual(grouped("12000ft + 25000 m"), "12 000ft + 25 000 m")
        XCTAssertEqual(grouped("rent = 150000 * 3"), "rent = 150 000 * 3")
    }

    func testLeavesShortNumbersAlone() {
        XCTAssertEqual(grouped("2000 + 2026"), "2000 + 2026")
        XCTAssertEqual(grouped("squawk 7700"), "squawk 7700")
    }

    func testSkipsNonQuantities() {
        XCTAssertEqual(grouped("#FF12345"), "#FF12345")
        XCTAssertEqual(grouped("#123456"), "#123456")
        XCTAssertEqual(grouped("0x12345"), "0x12345")
        XCTAssertEqual(grouped("B73712345"), "B73712345")
        XCTAssertEqual(grouped("01234"), "01234")
        XCTAssertEqual(grouped("0.123456"), "0.123456")
        XCTAssertEqual(grouped("12345:30"), "12345:30")
        XCTAssertEqual(grouped("v12345.1.2"), "v12345.1.2")
        XCTAssertEqual(grouped("12345.1.2"), "12345.1.2")
    }
}
