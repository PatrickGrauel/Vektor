import Foundation

/// A conservative, display-only scan of the original editor text. It never
/// evaluates a sheet or rewrites its contents, and all ranges are UTF-16.
public enum EditorSyntaxHighlighter {
    public enum Kind: Equatable, Sendable {
        case variable
        case unit
        case operatorSymbol
    }

    public struct Token: Equatable, Sendable {
        public let range: NSRange
        public let kind: Kind

        public init(range: NSRange, kind: Kind) {
            self.range = range
            self.kind = kind
        }
    }

    public static func tokens(in source: String,
                              isKnownUnit: (String) -> Bool) -> [Token] {
        let text = source as NSString
        var result: [Token] = []
        var variables = Set<String>()
        var unitCache: [String: Bool] = [:]
        var location = 0

        func knownUnit(_ token: String) -> Bool {
            if NumiPreprocessor.currencyCodes.contains(token.uppercased()) { return true }
            if let cached = unitCache[token] { return cached }
            let known = isKnownUnit(token)
            unitCache[token] = known
            return known
        }

        while location < text.length {
            let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
            let line = text.substring(with: lineRange)
            if let prepared = expressionText(in: line) {
                let scanned = scan(prepared)
                var candidates: [Token] = []
                var declarations: [Token] = []
                var unitIndices = Set<Int>()
                var isExpression = false
                var isProse = false

                for (index, item) in scanned.enumerated() {
                    let before = index > 0 ? scanned[index - 1] : nil
                    let after = index + 1 < scanned.count ? scanned[index + 1] : nil
                    let lower = item.text.lowercased()
                    let absoluteRange = NSRange(location: lineRange.location + item.range.location,
                                                length: item.range.length)

                    switch item.kind {
                    case .number:
                        isExpression = true
                    case .punctuation:
                        if mathOperators.contains(item.text) {
                            let token = Token(range: absoluteRange, kind: .operatorSymbol)
                            candidates.append(token)
                            // Keep assignment syntax coloured while its RHS
                            // is still being typed or contains an unknown name.
                            if item.text == "=", declarations.last?.kind == .variable {
                                declarations.append(token)
                            }
                        }
                    case .currency:
                        // The preprocessor accepts both $20 and 20$, with
                        // optional whitespace, but a currency sign in prose
                        // or on its own isn't a quantity.
                        guard before?.kind == .number || after?.kind == .number else {
                            isProse = true
                            continue
                        }
                        candidates.append(Token(range: absoluteRange, kind: .unit))
                    case .word:
                        let assignment = after?.text == "="
                            && (index + 2 >= scanned.count || scanned[index + 2].text != "=")
                            && (index == 0 || before?.text == ";")
                        if assignment {
                            variables.insert(lower)
                            let token = Token(range: absoluteRange, kind: .variable)
                            candidates.append(token)
                            declarations.append(token)
                            isExpression = true
                        } else if variables.contains(lower) {
                            candidates.append(Token(range: absoluteRange, kind: .variable))
                            isExpression = true
                        } else if ["am", "pm"].contains(lower),
                                  SuggestionEngine.isClockTime((prepared as NSString)
                                    .substring(to: NSMaxRange(item.range))) {
                            // Glued clock suffixes collide with SI units
                            // (pm = picometers, am = attometers).
                            continue
                        } else if isScale(item.text, after: before) {
                            // k/M/B are expanded as numeric scales before
                            // unit parsing, despite collisions with units.
                            continue
                        } else if lower == "in" {
                            // Only unambiguous inch forms get a unit tint.
                            // All other `in` tokens are conversion operators.
                            let inch = before?.kind == .number
                                && (after == nil
                                    || after.map { conversionWords.contains($0.text.lowercased()) } == true
                                    || (index >= 3 && scanned[index - 2].text.lowercased() == "ft"))
                            if inch {
                                candidates.append(Token(range: absoluteRange, kind: .unit))
                                unitIndices.insert(index)
                            }
                        } else {
                            let afterQuantity = before?.kind == .number
                                || before?.text == ")"
                                || before.map { variables.contains($0.text.lowercased()) } == true
                                || (index >= 2 && isScale(scanned[index - 1].text, after: scanned[index - 2]))
                            let conversionTarget = before.map { conversionWords.contains($0.text.lowercased()) } == true
                            let compound = (before?.text == "/" || before?.text == "*")
                                && index >= 2 && unitIndices.contains(index - 2)
                            if !isProse && !conversionWords.contains(lower)
                                && (afterQuantity || conversionTarget || compound), knownUnit(item.text) {
                                candidates.append(Token(range: absoluteRange, kind: .unit))
                                unitIndices.insert(index)
                            } else if conversionWords.contains(lower) || expressionWords.contains(lower) {
                                if aggregateWords.contains(lower) || lower == "prev" { isExpression = true }
                            } else if functionNames.contains(lower), after?.text == "(" {
                                isExpression = true
                            } else {
                                isProse = true
                            }
                        }
                    case .unknown:
                        isProse = true
                    }
                }

                // Ordinary notes can mention a defined name, `in`, or a unit.
                // Don't turn those words into colored math. An explicit
                // assignment target remains useful even with an unfinished RHS.
                result.append(contentsOf: isExpression && !isProse ? candidates : declarations)
            }
            location = NSMaxRange(lineRange)
        }
        return result
    }

    private enum LexicalKind: Equatable {
        case number, word, currency, punctuation, unknown
    }

    private struct Lexeme {
        let text: String
        let range: NSRange
        let kind: LexicalKind
    }

    private static let lexicalRegex = try! NSRegularExpression(pattern:
        #"((?:\d+(?:[.,]\d*)?|[.,]\d+)(?:[eE][+-]?\d+)?)|([\p{L}_°µμ][\p{L}\p{N}_°µμ]*)|([$€£¥₽₿])|([+\-−*/×÷^%=()\[\]{},;:<>!|&'\"])|(\S)"#)
    private static let trailingCommentRegex = try! NSRegularExpression(pattern: #"\s+(?://|")"#)
    private static let pageReferenceRegex = try! NSRegularExpression(pattern: #"@[A-Za-z0-9_-]+"#)
    private static let mathOperators: Set<String> = [
        "+", "-", "−", "*", "/", "×", "÷", "^", "%", "=", "<", ">", "!", "|", "&"
    ]

    private static let conversionWords: Set<String> = ["in", "to", "as", "into"]
    private static let aggregateWords: Set<String> = [
        "sum", "total", "average", "avg", "mean", "median", "minimum", "min",
        "maximum", "max", "range", "count", "stddev", "stdev", "std", "variance", "product", "prod"
    ]
    private static let expressionWords: Set<String> = aggregateWords.union([
        "prev", "pi", "e", "i", "of", "off", "on", "plus", "and", "with",
        "minus", "subtract", "without", "times", "multiplied", "by", "mul",
        "divided", "divide", "mod", "xor", "thousand", "million", "billion"
    ])
    private static let functionNames: Set<String> = [
        "sqrt", "cbrt", "abs", "round", "floor", "ceil", "fix", "sign",
        "sin", "cos", "tan", "asin", "acos", "atan", "atan2", "sinh", "cosh", "tanh",
        "log", "log10", "log2", "exp", "pow", "min", "max", "sum", "mean", "median",
        "crosswind", "headwind", "ground_speed", "density_altitude", "pressure_altitude"
    ]

    private static func scan(_ text: String) -> [Lexeme] {
        let ns = text as NSString
        return lexicalRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            let kind: LexicalKind
            if match.range(at: 1).location != NSNotFound { kind = .number }
            else if match.range(at: 2).location != NSNotFound { kind = .word }
            else if match.range(at: 3).location != NSNotFound { kind = .currency }
            else if match.range(at: 4).location != NSNotFound { kind = .punctuation }
            else { kind = .unknown }
            return Lexeme(text: ns.substring(with: match.range), range: match.range, kind: kind)
        }
    }

    private static func isScale(_ token: String, after before: Lexeme?) -> Bool {
        before?.kind == .number && ["k", "M", "B"].contains(token)
    }

    /// Replace excluded regions with equal-length spaces so offsets still
    /// point into the original text, including after emoji and CRLF endings.
    private static func expressionText(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("//") else { return nil }
        let mutable = NSMutableString(string: line)
        if let comment = trailingCommentRegex.firstMatch(in: line, range: NSRange(location: 0, length: mutable.length)) {
            let range = NSRange(location: comment.range.location, length: mutable.length - comment.range.location)
            mutable.replaceCharacters(in: range, with: String(repeating: " ", count: range.length))
        }
        let commentFree = mutable as String
        let colonLocations = commentFree.indices.filter { commentFree[$0] == ":" }
        if colonLocations.count == 1, let colon = colonLocations.first {
            let lhs = commentFree[..<colon].trimmingCharacters(in: .whitespaces)
            if !lhs.isEmpty && lhs.allSatisfy({ $0.isLetter || $0 == " " || $0 == "_" || $0 == "-" }) {
                let prefix = NSRange(commentFree.startIndex...colon, in: commentFree)
                mutable.replaceCharacters(in: prefix, with: String(repeating: " ", count: prefix.length))
            }
        }
        let labelFree = mutable as String
        for match in pageReferenceRegex.matches(in: labelFree, range: NSRange(location: 0, length: mutable.length)).reversed() {
            mutable.replaceCharacters(in: match.range, with: String(repeating: " ", count: match.range.length))
        }
        return mutable as String
    }
}
