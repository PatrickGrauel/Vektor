import AppKit

/// Bidirectional conversion between the raw markdown source the user
/// types/saves and the `NSAttributedString` the editor presents.
///
/// Atomic elements (checkbox, bullet marker, inline image, table) are
/// represented in the attributed string as a single `U+FFFC`
/// character + an `NSTextAttachment` subclass that carries the source
/// markdown plus its own drawing. The caret treats each attachment as
/// a single character, which fixes the cluster of UX issues (cursor
/// navigation, selection leakage, drawing layering, click handling)
/// that the previous overlay-on-top-of-hidden-text approach had.
///
/// Inline formatting (headings, bold, italic, code, hashtags, wiki
/// links, strikethrough, highlight, footnotes, blockquotes, fenced
/// code blocks) still lives as plain text + colour/font attributes —
/// these benefit from the existing cursor-aware syntax-hiding pass
/// and don't need to be atomic.
enum NotesRenderer {

    private static let attachmentChar: Character = "\u{FFFC}"

    // MARK: - Public API

    /// Build the attributed string the NSTextView should display from
    /// a raw markdown source.
    static func render(markdown: String, fontSize: CGFloat) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: NSColor.labelColor,
        ]

        // Line-by-line walk. Table detection consumes multiple lines;
        // everything else is handled per-line then per-token.
        let lines = markdown.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            // Table block? Look ahead: a header line, a separator
            // line, then zero or more data rows.
            if let (block, consumed) = consumeTableBlock(lines: lines, from: i) {
                let attachment = TableAttachment(data: block,
                                                 baseFontSize: fontSize,
                                                 maxWidth: 720)
                out.append(NSAttributedString(attachment: attachment))
                out.append(NSAttributedString(string: "\n", attributes: base))
                i += consumed
                continue
            }
            renderLine(lines[i], into: out, base: base, fontSize: fontSize)
            // Re-add the newline that `components(separatedBy:)` ate,
            // except after the very last line.
            if i < lines.count - 1 {
                out.append(NSAttributedString(string: "\n", attributes: base))
            }
            i += 1
        }
        return out
    }

    /// Walk the editor's attributed storage and rebuild the raw
    /// markdown source. Attachments contribute their `sourceMarkdown`;
    /// plain characters pass through.
    static func serialise(storage: NSAttributedString) -> String {
        let ns = storage.string as NSString
        var out = ""
        var i = 0
        let length = ns.length
        while i < length {
            let ch = ns.character(at: i)
            if ch == 0xFFFC {
                if let attachment = storage.attribute(.attachment,
                                                      at: i,
                                                      effectiveRange: nil) as? MarkdownSerialisable {
                    out += attachment.sourceMarkdown
                }
                i += 1
            } else {
                out += ns.substring(with: NSRange(location: i, length: 1))
                i += 1
            }
        }
        return out
    }

    // MARK: - Line rendering

    private static func renderLine(_ line: String,
                                   into out: NSMutableAttributedString,
                                   base: [NSAttributedString.Key: Any],
                                   fontSize: CGFloat) {
        // Leading whitespace stays as plain chars (preserves user
        // indent levels for nested lists / quotes).
        let nsline = line as NSString
        var i = 0
        // Step over leading whitespace and copy as-is.
        while i < nsline.length,
              let scalar = Unicode.Scalar(nsline.character(at: i)),
              scalar == " " || scalar == "\t" {
            out.append(NSAttributedString(string: String(scalar), attributes: base))
            i += 1
        }
        // What follows the indent decides the line type:
        //   1) `- [ ]` / `- [x]` → bullet attachment + checkbox attachment + rest
        //   2) `- ` / `* ` / `+ ` → bullet attachment + rest
        //   3) anything else → just render the remaining chars
        let remaining = nsline.substring(from: i)
        if let chk = matchCheckboxLine(remaining) {
            let marker = String(remaining.prefix(1))   // "-" / "*" / "+"
            out.append(NSAttributedString(attachment:
                BulletAttachment(marker: marker, glyphSize: fontSize)))
            out.append(NSAttributedString(attachment:
                CheckboxAttachment(checked: chk.checked, glyphSize: fontSize)))
            // Skip the consumed prefix; render the rest as inline.
            renderInline(String(remaining.dropFirst(chk.consumed)),
                         into: out, base: base, fontSize: fontSize)
            return
        }
        if let bullet = matchBulletLine(remaining) {
            out.append(NSAttributedString(attachment:
                BulletAttachment(marker: String(bullet.marker), glyphSize: fontSize)))
            renderInline(String(remaining.dropFirst(bullet.consumed)),
                         into: out, base: base, fontSize: fontSize)
            return
        }
        renderInline(remaining, into: out, base: base, fontSize: fontSize)
    }

    /// Render the inline-text portion of a line, walking for image
    /// markdown to substitute attachments. Plain characters pass
    /// through as text — the existing inline styling pass in
    /// MarkdownTextEditor takes care of bold / italic / hashtag etc.
    private static func renderInline(_ text: String,
                                     into out: NSMutableAttributedString,
                                     base: [NSAttributedString.Key: Any],
                                     fontSize: CGFloat) {
        let ns = text as NSString
        let pattern = #"!\[([^\]]*)\]\(notes-asset://([^)]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            out.append(NSAttributedString(string: text, attributes: base))
            return
        }
        let matches = regex.matches(in: text,
                                    range: NSRange(location: 0, length: ns.length))
        var cursor = 0
        for m in matches {
            // Text before the image.
            if m.range.location > cursor {
                let pre = ns.substring(with: NSRange(location: cursor,
                                                     length: m.range.location - cursor))
                out.append(NSAttributedString(string: pre, attributes: base))
            }
            let alt = m.numberOfRanges >= 2
                ? ns.substring(with: m.range(at: 1))
                : ""
            let path = m.numberOfRanges >= 3
                ? ns.substring(with: m.range(at: 2))
                : ""
            let urlString = "notes-asset://\(path)"
            out.append(NSAttributedString(attachment:
                InlineImageAttachment(assetURLString: urlString,
                                      altText: alt,
                                      maxWidth: 360)))
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length {
            let trailing = ns.substring(from: cursor)
            out.append(NSAttributedString(string: trailing, attributes: base))
        }
    }

    // MARK: - Match helpers

    private struct CheckboxMatch {
        let checked: Bool
        let consumed: Int   // chars to drop after the bullet+checkbox pair
    }

    /// Match `- [ ] ` / `- [x] ` / `* [X] ` (etc.) at the START of
    /// the post-indent string. Returns the checked state and the
    /// number of chars to consume (which the bullet + checkbox
    /// attachments take the place of).
    private static func matchCheckboxLine(_ text: String) -> CheckboxMatch? {
        let pattern = #"^[-*+][ \t]+\[( |x|X)\][ \t]+"#
        let ns = text as NSString
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: text,
                                       range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges >= 2 else { return nil }
        let mark = ns.substring(with: m.range(at: 1)).lowercased()
        return CheckboxMatch(checked: mark == "x", consumed: m.range.length)
    }

    private struct BulletMatch {
        let marker: Character
        let consumed: Int
    }
    /// Match a plain bullet `- ` / `* ` / `+ ` at the start of the
    /// post-indent string. Excludes checkbox prefixes (caller handles
    /// those separately). Numbered lists `1. ` are not bullets —
    /// they stay plain text and get inline styling later.
    private static func matchBulletLine(_ text: String) -> BulletMatch? {
        let ns = text as NSString
        guard ns.length >= 2 else { return nil }
        let first = ns.character(at: 0)
        let second = ns.character(at: 1)
        let isMarker = first == 0x2D || first == 0x2A || first == 0x2B   // - * +
        guard isMarker, second == 0x20 else { return nil }
        // Don't swallow a checkbox prefix.
        if ns.length >= 5 {
            let third = ns.character(at: 2)
            if third == 0x5B { return nil }   // `[`
        }
        return BulletMatch(marker: Character(Unicode.Scalar(first)!), consumed: 2)
    }

    // MARK: - Tables

    /// Inspect `lines` starting at index `from`. If the run forms a
    /// markdown table (header + separator + ≥0 data rows), return the
    /// parsed `NotesTableData` plus the number of lines consumed.
    private static func consumeTableBlock(lines: [String],
                                          from start: Int) -> (NotesTableData, Int)? {
        let isPipeRow: (String) -> Bool = { line in
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.hasPrefix("|") && t.hasSuffix("|")
        }
        guard start < lines.count, isPipeRow(lines[start]) else { return nil }
        // Find run length.
        var end = start
        while end < lines.count, isPipeRow(lines[end]) { end += 1 }
        let block = Array(lines[start..<end])
        guard block.count >= 2 else { return nil }
        // Identify separator line.
        let sepIdx = block.firstIndex { line -> Bool in
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let inner = t.dropFirst().dropLast()
            let cells = inner.split(separator: "|", omittingEmptySubsequences: false)
            return !cells.isEmpty && cells.allSatisfy { cell in
                let s = cell.trimmingCharacters(in: .whitespaces)
                return !s.isEmpty && s.allSatisfy { $0 == "-" || $0 == ":" }
            }
        }
        guard let sep = sepIdx, sep >= 1 else { return nil }

        func cells(_ line: String) -> [String] {
            let t = line.trimmingCharacters(in: .whitespaces)
            let inner = t
                .dropFirst(t.hasPrefix("|") ? 1 : 0)
                .dropLast(t.hasSuffix("|") ? 1 : 0)
            return inner
                .split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
        }
        let headers = cells(block[sep - 1])
        let dataRows = (sep + 1) < block.count
            ? Array(block[(sep + 1)...]).map(cells)
            : []
        // Round-trip-safe source markdown.
        let source = block.joined(separator: "\n")
        return (NotesTableData(headers: headers,
                               rows: dataRows,
                               sourceMarkdown: source),
                block.count)
    }
}
