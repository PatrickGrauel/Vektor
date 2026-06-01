import SwiftUI
import UIKit
import VektorEngine

/// The calculator's editing surface — the iOS analogue of the macOS
/// `UnifiedEditor`. A monospaced, editable `UITextView` on the left with
/// live syntax highlighting; a results gutter on the right that draws each
/// line's engine result aligned to that line's fragment. A keyboard
/// accessory bar surfaces the live `SuggestionEngine` completion plus the
/// natural-language tokens that are slow to type on a phone.
struct CalcEditor: UIViewRepresentable {
    @Binding var text: String
    var results: [LineResult]
    /// Width of the result gutter. Narrower on compact (iPhone) layouts.
    var gutterWidth: CGFloat = 150
    /// Returns true when an `@slug` points to an existing document — drives
    /// resolved (accent + solid underline) vs unresolved (muted + dotted)
    /// styling of jump links.
    var resolvePageReference: (String) -> Bool = { _ in false }

    func makeUIView(context: Context) -> CalcEditorView {
        let view = CalcEditorView()
        view.textView.delegate = context.coordinator
        context.coordinator.view = view
        context.coordinator.resolvePageReference = resolvePageReference
        view.textView.text = text
        context.coordinator.applyLineColors(to: view.textView.textStorage)
        view.refreshSuggestion()
        return view
    }

    func updateUIView(_ view: CalcEditorView, context: Context) {
        context.coordinator.resolvePageReference = resolvePageReference
        if view.textView.text != text {
            view.textView.text = text
            context.coordinator.applyLineColors(to: view.textView.textStorage)
        }
        view.gutterWidth = gutterWidth
        view.apply(results: results)
        view.refreshSuggestion()
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CalcEditor
        weak var view: CalcEditorView?
        var resolvePageReference: (String) -> Bool = { _ in false }
        init(_ parent: CalcEditor) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            applyLineColors(to: textView.textStorage)
            view?.gutter.setNeedsDisplay()
            view?.refreshSuggestion()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            view?.refreshSuggestion()
        }

        // The gutter rides the text view's scroll position (UITextView is a
        // UIScrollView, so its delegate gets scroll callbacks).
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            view?.gutter.setNeedsDisplay()
        }

        // MARK: - Syntax highlighting
        //
        // Recolours the whole document on each edit. The macOS version
        // scopes to the edited line via an NSTextStorageDelegate, but
        // calculator docs are short and a full pass per keystroke is cheap
        // — and doing it after the edit (here) avoids any processEditing
        // re-entrancy pitfalls.

        func applyLineColors(to storage: NSTextStorage) {
            let fullText = storage.string as NSString
            let total = fullText.length
            guard total > 0 else { return }
            let scope = NSRange(location: 0, length: total)

            // Clear link styling across the scope before re-applying, so a
            // deleted `@ref` doesn't leave a dangling underline behind.
            storage.removeAttribute(.underlineStyle, range: scope)
            storage.removeAttribute(Self.pageReferenceAttributeKey, range: scope)

            let defaultColor = VektorTheme.UI.text
            let headerColor  = VektorTheme.UI.accent
            let commentColor = VektorTheme.UI.muted

            var loc = 0
            while loc < total {
                let lineRange = fullText.lineRange(for: NSRange(location: loc, length: 0))
                let lineString = fullText.substring(with: lineRange)
                let trimmed = lineString.trimmingCharacters(in: .whitespacesAndNewlines)
                let colour: UIColor
                if trimmed.hasPrefix("#") {
                    colour = headerColor
                } else if trimmed.hasPrefix("//") {
                    colour = commentColor
                } else {
                    colour = defaultColor
                }
                storage.addAttribute(.foregroundColor, value: colour, range: lineRange)
                if !trimmed.hasPrefix("//") {
                    applyTrailingComment(storage, lineString, lineRange, commentColor)
                }
                applyPageRefs(storage, lineString, lineRange)
                let newLoc = lineRange.location + lineRange.length
                if newLoc == loc { break }
                loc = newLoc
            }
        }

        /// A trailing `// …` comment on an expression line. The leading
        /// `\s+` protects URLs like `http://…` from being mis-styled.
        private static let trailingCommentRegex = try? NSRegularExpression(pattern: #"\s+(//[^\r\n]*)"#)
        private func applyTrailingComment(_ storage: NSTextStorage, _ lineString: String,
                                          _ lineRange: NSRange, _ color: UIColor) {
            guard let regex = Self.trailingCommentRegex else { return }
            let ns = lineString as NSString
            guard let m = regex.firstMatch(in: lineString, range: NSRange(location: 0, length: ns.length)),
                  m.numberOfRanges >= 2 else { return }
            let local = m.range(at: 1)
            let abs = NSRange(location: lineRange.location + local.location, length: local.length)
            storage.addAttribute(.foregroundColor, value: color, range: abs)
        }

        /// Attribute key a future tap-handler reads to navigate `@ref` jumps.
        static let pageReferenceAttributeKey = NSAttributedString.Key("vektor.calculator.pageRef")
        private static let pageRefRegex = try? NSRegularExpression(pattern: #"@[A-Za-z0-9_-]+"#)
        private func applyPageRefs(_ storage: NSTextStorage, _ lineString: String, _ lineRange: NSRange) {
            guard let regex = Self.pageRefRegex else { return }
            let ns = lineString as NSString
            let resolvedColor = VektorTheme.UI.accent
            let unresolvedColor = VektorTheme.UI.muted
            let resolvedUnderline = NSUnderlineStyle.single.rawValue
            let unresolvedUnderline = NSUnderlineStyle([.single, .patternDot]).rawValue
            regex.enumerateMatches(in: lineString, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
                guard let m = match else { return }
                let abs = NSRange(location: lineRange.location + m.range.location, length: m.range.length)
                let slug = String(ns.substring(with: m.range).lowercased().dropFirst())
                let resolves = self.resolvePageReference(slug)
                storage.addAttribute(.foregroundColor, value: resolves ? resolvedColor : unresolvedColor, range: abs)
                storage.addAttribute(.underlineStyle, value: resolves ? resolvedUnderline : unresolvedUnderline, range: abs)
                storage.addAttribute(Self.pageReferenceAttributeKey, value: slug, range: abs)
            }
        }
    }
}

/// Container: an editable text view + a result-drawing gutter laid out side
/// by side. The text view scrolls natively (caret stays visible while
/// typing); the gutter redraws in sync.
final class CalcEditorView: UIView {
    static let font = UIFont.monospacedSystemFont(ofSize: 16, weight: .regular)

    let textView: UITextView
    let gutter: GutterView
    var gutterWidth: CGFloat = 150 { didSet { setNeedsLayout() } }

    private let accessory = UIToolbar()
    private var lastSuggestion: String?

    override init(frame: CGRect) {
        // Explicit TextKit-1 stack so `layoutManager` +
        // `boundingRect(forGlyphRange:in:)` (used by the gutter) are reliable.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        textView = UITextView(frame: .zero, textContainer: container)
        gutter = GutterView()

        super.init(frame: frame)

        backgroundColor = VektorTheme.UI.background

        textView.backgroundColor = .clear
        textView.font = Self.font
        textView.textColor = VektorTheme.UI.text
        textView.tintColor = VektorTheme.UI.accent
        textView.typingAttributes = [
            .font: Self.font,
            .foregroundColor: VektorTheme.UI.text,
        ]
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.spellCheckingType = .no
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 280, right: 8)

        accessory.sizeToFit()
        textView.inputAccessoryView = accessory
        addSubview(textView)

        gutter.textView = textView
        gutter.backgroundColor = .clear
        gutter.contentMode = .redraw
        gutter.isUserInteractionEnabled = false
        gutter.clipsToBounds = true
        addSubview(gutter)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let textWidth = max(0, bounds.width - gutterWidth)
        textView.frame = CGRect(x: 0, y: 0, width: textWidth, height: bounds.height)
        gutter.frame = CGRect(x: textWidth, y: 0, width: gutterWidth, height: bounds.height)
        gutter.setNeedsDisplay()
    }

    func apply(results: [LineResult]) {
        gutter.results = results
        gutter.setNeedsDisplay()
    }

    // MARK: - Smart suggestion bar

    /// Recompute the live completion at the caret and, if it changed, rebuild
    /// the accessory bar. A unit/keyword completion (`SuggestionEngine`) takes
    /// priority; on a blank doc we surface a rotating demo hint instead.
    func refreshSuggestion() {
        let text = textView.text ?? ""
        let caret = textView.selectedRange.location
        var suggestion = SuggestionEngine.suggest(in: text, cursor: caret)
        var isHint = false
        if suggestion == nil, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            suggestion = SuggestionEngine.demoHint(rotation: 0)
            isHint = true
        }
        guard suggestion != lastSuggestion else { return }
        lastSuggestion = suggestion
        rebuildAccessory(suggestion: suggestion, isHint: isHint)
    }

    private func rebuildAccessory(suggestion: String?, isHint: Bool) {
        var items: [UIBarButtonItem] = []

        if let s = suggestion, !s.isEmpty {
            // A hint is a full sample line ("try …"); a completion finishes
            // the current token ("⤷ km").
            let title = isHint ? "try  \(s.prefix(28))" : "⤷ \(s)"
            let chip = UIBarButtonItem(title: title, primaryAction: UIAction { [weak self] _ in
                self?.textView.insertText(s)
                self?.refreshSuggestion()
            })
            chip.tintColor = VektorTheme.UI.accent
            items.append(chip)
            items.append(UIBarButtonItem(barButtonSystemItem: .fixedSpace, target: nil, action: nil))
        }

        func token(_ title: String, _ insert: String) -> UIBarButtonItem {
            UIBarButtonItem(title: title, primaryAction: UIAction { [weak self] _ in
                self?.textView.insertText(insert)
            })
        }
        items.append(contentsOf: [
            token("in", " in "),
            token("to", " to "),
            token("prev", "prev"),
            token("EUR", " EUR"),
            token("USD", " USD"),
            UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
        ])
        let done = UIBarButtonItem(title: "Done",
                                   primaryAction: UIAction { [weak self] _ in self?.textView.resignFirstResponder() })
        done.style = .done
        items.append(done)

        accessory.setItems(items, animated: false)
        accessory.sizeToFit()
    }
}

/// Draws per-line results aligned to the text view's line fragments.
final class GutterView: UIView {
    weak var textView: UITextView?
    var results: [LineResult] = []

    private static let font = UIFont.monospacedSystemFont(ofSize: 16, weight: .regular)

    override func draw(_ rect: CGRect) {
        // Hairline separating editor from gutter.
        VektorTheme.UI.divider.setFill()
        UIRectFill(CGRect(x: 0, y: 0, width: 0.5, height: bounds.height))

        guard let tv = textView, let layout = tv.layoutManager as NSLayoutManager?,
              let storage = tv.textStorage as NSTextStorage?
        else { return }
        let container = tv.textContainer
        let fullText = storage.string as NSString
        let insetTop = tv.textContainerInset.top
        let offsetY = tv.contentOffset.y

        let lineStarts = Self.lineStartOffsets(fullText)

        for r in results {
            guard r.line < lineStarts.count, let value = Self.displayValue(r) else { continue }
            let start = lineStarts[r.line]
            let end = (r.line + 1 < lineStarts.count) ? lineStarts[r.line + 1] : fullText.length
            let rawLen = max(0, end - start)
            let len = max(1, min(rawLen, fullText.length - start))
            guard start < fullText.length else { continue }

            let charRange = NSRange(location: start, length: len)
            let glyphRange = layout.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
            let lineRect = layout.boundingRect(forGlyphRange: glyphRange, in: container)
            let y = lineRect.minY + insetTop - offsetY

            if y + lineRect.height < 0 || y > bounds.height { continue }
            draw(value: value, color: Self.color(r), atY: y)
        }
    }

    private func draw(value: String, color: UIColor, atY y: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: color]
        let size = (value as NSString).size(withAttributes: attrs)
        let x = bounds.width - size.width - 12   // right-aligned, 12pt trailing
        (value as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: attrs)
    }

    // Numi-style: lines that don't produce a value render blank.
    private static func displayValue(_ r: LineResult) -> String? {
        switch r.kind {
        case .expression, .timezone:
            guard let v = r.value, !v.isEmpty, v != "undefined", v != "null" else { return nil }
            return v
        default:
            return nil
        }
    }

    private static func color(_ r: LineResult) -> UIColor {
        switch r.kind {
        case .timezone: return VektorTheme.UI.accent
        default:        return VektorTheme.UI.text
        }
    }

    private static func lineStartOffsets(_ text: NSString) -> [Int] {
        var starts = [0]
        var i = 0
        let len = text.length
        while i < len {
            if text.character(at: i) == 10 { starts.append(i + 1) }   // "\n"
            i += 1
        }
        return starts
    }
}
