import Foundation

/// Visual thousands-grouping for the calculator editor. The text itself is
/// never touched — editors widen the gap after each returned position
/// (kerning), so `22111555.11` *reads* as `22 111 555.11` while the stored
/// text, the caret, copy/paste and the parser all see the raw digits.
///
/// Rules (keep the editor honest — never group something that isn't a
/// quantity):
///   • only integer runs of 5+ digits (`12000`; `2000` / years stay plain)
///   • never a run with a leading zero (`01234` — IDs, zip codes)
///   • never a run touching a letter, `_`, `#`, `.`, `:` or another digit on
///     the left (`B73712`, `0x1F2A3`, `#FF0000`, fractional digits
///     `0.123456`, clock `12:34567`)
///   • never a run followed by `:` or `.digit.` (times, version strings)
///   • a trailing unit glued on the right is fine (`12000ft`)
public enum DigitGrouping {
    /// UserDefaults key for the on/off setting. Absent → on.
    public static let defaultsKey = "vektor.editor.digitGrouping"

    public static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }

    private static let runRegex = try? NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_#.:])[1-9]\d{4,}(?![\d:]|\.\d+\.)"#
    )

    /// UTF-16 offsets (into `line`) of the digits after which a group gap
    /// belongs. For `22111555.11` → offsets of the `2` at index 1 and the
    /// `1` at index 4.
    public static func gapPositions(in line: String) -> [Int] {
        guard let regex = runRegex else { return [] }
        let ns = line as NSString
        var out: [Int] = []
        regex.enumerateMatches(in: line, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let r = m?.range else { return }
            // Gap after every digit whose remaining count is a positive
            // multiple of 3: for 8 digits → after index 1 and 4.
            var i = r.length - 3
            while i > 0 {
                out.append(r.location + i - 1)
                i -= 3
            }
        }
        return out.sorted()
    }
}
