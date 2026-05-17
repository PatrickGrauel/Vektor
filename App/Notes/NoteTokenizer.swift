import Foundation

/// Pure-string helpers for the Notes pane. Two token kinds:
///
///   - `#tag` and `#tag/sub` — hierarchical tags, used by the sidebar
///     tree. A tag stops at whitespace, punctuation other than `/`, or
///     end-of-line. `##heading` (markdown header) is NOT a tag —
///     trailing `#` characters are eaten as header syntax.
///   - `[[Wiki Link]]` — links to other notes by title. Resolved at
///     render time so renames don't break links automatically (a wiki-
///     link that no longer matches any note is shown as broken).
enum NoteTokenizer {

    /// All hashtags in `text`, lowercased and deduplicated, in the
    /// order they first appear.
    static func tags(in text: String) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for tag in scanTags(in: text) {
            let lower = tag.lowercased()
            if !seen.contains(lower) {
                seen.insert(lower)
                ordered.append(lower)
            }
        }
        return ordered
    }

    /// All `[[Title]]` wiki-link targets in `text`, in order of appearance.
    /// Returns the inner content verbatim — case-sensitive matching is
    /// the caller's problem (the sidebar lookup uses case-insensitive
    /// title comparison).
    static func wikiLinkTargets(in text: String) -> [String] {
        var results: [String] = []
        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == "[",
               text.index(after: i) < text.endIndex,
               text[text.index(after: i)] == "[" {
                let openEnd = text.index(i, offsetBy: 2)
                if let closeRange = text.range(of: "]]", range: openEnd..<text.endIndex) {
                    let inner = String(text[openEnd..<closeRange.lowerBound])
                        .trimmingCharacters(in: .whitespaces)
                    if !inner.isEmpty {
                        results.append(inner)
                    }
                    i = closeRange.upperBound
                    continue
                }
            }
            i = text.index(after: i)
        }
        return results
    }

    /// Token ranges for the editor's inline syntax highlighter. Returned
    /// as `(NSRange, TokenKind)` pairs so the caller can apply colour
    /// without re-scanning. Ranges are over `text` as an NSString
    /// (UTF-16 indices), suitable for direct use with
    /// `NSMutableAttributedString.setAttributes(_:range:)`.
    static func highlightRanges(in text: String) -> [(NSRange, TokenKind)] {
        let ns = text as NSString
        var ranges: [(NSRange, TokenKind)] = []

        // Hashtags. Scan over the NSString so the resulting NSRanges
        // line up with what NSTextView expects.
        scanTagRanges(in: ns) { range in
            ranges.append((range, .tag))
        }
        // Wiki-links: `[[ ... ]]`.
        scanWikiLinkRanges(in: ns) { range in
            ranges.append((range, .wikiLink))
        }
        // Bold (**text**) and emphasis (_text_) — first markdown pass
        // that survives in the editor without a full markdown parser.
        scanInlineRanges(in: ns, opener: "**", closer: "**") { range in
            ranges.append((range, .bold))
        }
        scanInlineRanges(in: ns, opener: "_", closer: "_") { range in
            ranges.append((range, .emphasis))
        }
        // Inline code (`code`).
        scanInlineRanges(in: ns, opener: "`", closer: "`") { range in
            ranges.append((range, .code))
        }
        // ATX headings: a `#` (or up to 6) followed by space at line start.
        scanHeadingRanges(in: ns) { range in
            ranges.append((range, .heading))
        }
        return ranges
    }

    enum TokenKind {
        case tag, wikiLink, bold, emphasis, code, heading
    }

    // MARK: - Internals

    private static func scanTags(in text: String) -> [String] {
        var results: [String] = []
        scanTagRanges(in: text as NSString) { range in
            // Drop the leading `#` for the tag string itself.
            let r = NSRange(location: range.location + 1, length: range.length - 1)
            if r.length > 0 {
                results.append((text as NSString).substring(with: r))
            }
        }
        return results
    }

    private static func scanTagRanges(in ns: NSString, body: (NSRange) -> Void) {
        let length = ns.length
        var i = 0
        while i < length {
            let ch = ns.character(at: i)
            if ch == UInt16(("#" as Character).asciiValue!) {
                // Reject `##` (markdown heading) — only a single leading
                // hash counts as a tag, and it must be at the start of
                // the line OR preceded by whitespace.
                let prev: unichar = i == 0 ? UInt16(("\n" as Character).asciiValue!)
                                            : ns.character(at: i - 1)
                let prevIsBoundary = prev == UInt16(("\n" as Character).asciiValue!)
                    || prev == UInt16((" " as Character).asciiValue!)
                    || prev == UInt16(("\t" as Character).asciiValue!)
                let next: unichar = (i + 1) < length ? ns.character(at: i + 1) : 0
                let nextIsHashOrEmpty = next == 0
                    || next == UInt16(("#" as Character).asciiValue!)
                    || next == UInt16((" " as Character).asciiValue!)
                if prevIsBoundary && !nextIsHashOrEmpty {
                    // Walk forward while the char is a valid tag char.
                    var j = i + 1
                    while j < length, isTagChar(ns.character(at: j)) {
                        j += 1
                    }
                    if j > i + 1 {
                        body(NSRange(location: i, length: j - i))
                    }
                    i = j
                    continue
                }
            }
            i += 1
        }
    }

    private static func isTagChar(_ ch: unichar) -> Bool {
        // a-z, A-Z, 0-9, `_`, `-`, `/`
        if (ch >= 0x30 && ch <= 0x39) ||   // 0-9
           (ch >= 0x41 && ch <= 0x5A) ||   // A-Z
           (ch >= 0x61 && ch <= 0x7A) {    // a-z
            return true
        }
        if ch == UInt16(("_" as Character).asciiValue!) { return true }
        if ch == UInt16(("-" as Character).asciiValue!) { return true }
        if ch == UInt16(("/" as Character).asciiValue!) { return true }
        return false
    }

    private static func scanWikiLinkRanges(in ns: NSString, body: (NSRange) -> Void) {
        let length = ns.length
        var i = 0
        while i < length - 1 {
            if ns.character(at: i) == UInt16(("[" as Character).asciiValue!),
               ns.character(at: i + 1) == UInt16(("[" as Character).asciiValue!) {
                // Find closing `]]`.
                let searchStart = i + 2
                let searchRange = NSRange(location: searchStart, length: length - searchStart)
                let closeRange = ns.range(of: "]]", options: [], range: searchRange)
                if closeRange.location != NSNotFound {
                    let total = NSRange(location: i,
                                        length: closeRange.location + closeRange.length - i)
                    body(total)
                    i = total.location + total.length
                    continue
                }
            }
            i += 1
        }
    }

    /// Scan paired-delimiter inline spans like `**bold**`. Pairs are
    /// matched within a single line (no multi-line spans), and a span
    /// must contain at least one non-delimiter character.
    private static func scanInlineRanges(in ns: NSString,
                                         opener: String,
                                         closer: String,
                                         body: (NSRange) -> Void) {
        let length = ns.length
        let openerLen = (opener as NSString).length
        let closerLen = (closer as NSString).length
        var i = 0
        while i <= length - openerLen {
            let r = NSRange(location: i, length: openerLen)
            if ns.substring(with: r) == opener {
                let searchStart = i + openerLen
                if searchStart >= length { break }
                // Stop the search at the next newline so a stray `**`
                // doesn't paint half the document bold.
                let lineEndRange = ns.range(of: "\n", options: [],
                                            range: NSRange(location: searchStart,
                                                           length: length - searchStart))
                let lineEnd = lineEndRange.location == NSNotFound
                    ? length
                    : lineEndRange.location
                let closeRange = ns.range(of: closer, options: [],
                                          range: NSRange(location: searchStart,
                                                         length: lineEnd - searchStart))
                if closeRange.location != NSNotFound,
                   closeRange.location > searchStart {
                    let total = NSRange(location: i,
                                        length: closeRange.location + closerLen - i)
                    body(total)
                    i = total.location + total.length
                    continue
                }
            }
            i += 1
        }
    }

    private static func scanHeadingRanges(in ns: NSString, body: (NSRange) -> Void) {
        let length = ns.length
        var lineStart = 0
        while lineStart < length {
            let lineRange = ns.lineRange(for: NSRange(location: lineStart, length: 0))
            // Strip trailing newline from the highlight range so the
            // colour doesn't bleed into the next line's start.
            var end = lineRange.location + lineRange.length
            if end > lineRange.location,
               ns.character(at: end - 1) == UInt16(("\n" as Character).asciiValue!) {
                end -= 1
            }
            // Skip leading whitespace.
            var i = lineRange.location
            while i < end,
                  ns.character(at: i) == UInt16((" " as Character).asciiValue!) {
                i += 1
            }
            // Count up to 6 leading `#`.
            var hashes = 0
            while i + hashes < end,
                  ns.character(at: i + hashes) == UInt16(("#" as Character).asciiValue!),
                  hashes < 6 {
                hashes += 1
            }
            if hashes > 0,
               (i + hashes) < end,
               ns.character(at: i + hashes) == UInt16((" " as Character).asciiValue!) {
                body(NSRange(location: lineRange.location, length: end - lineRange.location))
            }
            lineStart = lineRange.location + lineRange.length
        }
    }
}
