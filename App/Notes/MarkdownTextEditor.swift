import SwiftUI
import AppKit

/// NSTextView-backed markdown editor with Bear-style inline rendering.
///
/// Three layers of "feels like Bear" on top of plain NSTextView editing:
///
///   1. **Inline styling.** Headings render at their final size,
///      bold/italic/code use the right typography, hashtags +
///      `[[wiki-links]]` go accent-coloured.
///   2. **Cursor-aware syntax hiding** (the killer feature). Markdown
///      syntax characters (`**`, `_`, `#`, `` ` ``, `[[`, `]]`) are
///      *invisible* on lines the cursor isn't on, and dimly visible on
///      the cursor's line so the user can still edit them. Moving the
///      caret triggers a re-paint.
///   3. **Inline images.** `![](notes-asset://...)` collapses into the
///      actual image via NSTextAttachment.
///   4. **Interactive checkboxes.** `- [ ]` / `- [x]` render as
///      clickable SF Symbol attachments — click toggles state.
///   5. **List auto-continue.** Pressing Return inside a `- ` / `* ` /
///      `1. ` / `- [ ] ` line inserts the same prefix; pressing Return
///      on an empty list line exits the list (Bear / Markdown.app
///      convention).
struct MarkdownTextEditor: NSViewRepresentable {
    @Binding var text: String
    @ObservedObject var controller: NotesEditorController
    @ObservedObject var appearance: NotesAppearanceSettings = .shared

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NotesEditorTextView.scrollableTextView()
        let textView = scroll.documentView as! NotesEditorTextView
        textView.coordinator = context.coordinator
        textView.delegate = context.coordinator
        textView.allowsUndo = true
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.smartInsertDeleteEnabled = false
        textView.usesFindBar = true
        textView.textContainerInset = NSSize(width: 24, height: 18)
        let baseSize = CGFloat(appearance.fontSize)
        textView.font = appearance.font.baseFont(size: baseSize)
        textView.backgroundColor = NSColor(appearance.theme.background)
        textView.drawsBackground = true
        textView.textColor = NSColor(appearance.theme.text)
        textView.insertionPointColor = NSColor(appearance.theme.accent)

        // Initial render: parse markdown → attributed string with
        // atomic-element attachments + inline styling.
        context.coordinator.renderFullDocument(into: textView,
                                               markdown: text)
        controller.textView = textView
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NotesEditorTextView else { return }
        controller.textView = textView
        // Keep the chrome in sync with live appearance changes.
        let baseSize = CGFloat(appearance.fontSize)
        let wantFont = appearance.font.baseFont(size: baseSize)
        if textView.font != wantFont {
            textView.font = wantFont
        }
        textView.backgroundColor = NSColor(appearance.theme.background)
        textView.textColor = NSColor(appearance.theme.text)
        textView.insertionPointColor = NSColor(appearance.theme.accent)
        // Only re-render when the source has changed from outside our
        // own write path (note switched, undo, external edit). If the
        // binding matches what we last serialised, skip — re-rendering
        // would destroy selection + undo history for no gain.
        if context.coordinator.lastRenderedSource != text {
            let selected = textView.selectedRanges
            context.coordinator.renderFullDocument(into: textView,
                                                   markdown: text)
            // Try to restore the prior selection. If the text length
            // changed (atomic-element collapse) selection clamping
            // keeps us from indexing past end.
            let length = (textView.string as NSString).length
            let clamped = selected.compactMap { value -> NSValue? in
                let r = value.rangeValue
                let loc = min(r.location, length)
                let len = min(r.length, length - loc)
                return NSValue(range: NSRange(location: loc, length: len))
            }
            if !clamped.isEmpty { textView.selectedRanges = clamped }
        } else {
            // Re-apply inline styling only (theme / font / size
            // change). Doesn't mutate the storage's character
            // contents — just attributes.
            context.coordinator.applyInlineStyling(to: textView)
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: MarkdownTextEditor
        /// Last caret-line range we re-painted for; lets us skip the
        /// re-highlight pass when the user is typing within the same
        /// line (selection changes constantly but the *line* doesn't).
        private var lastCaretLineRange: NSRange = NSRange(location: NSNotFound, length: 0)
        /// What we last serialised into the @Binding text. Lets
        /// updateNSView decide whether an incoming text change came
        /// from outside (re-render needed) vs from our own
        /// textDidChange path (skip).
        var lastRenderedSource: String = ""
        /// Set during our own attributed-string mutations so the
        /// textDidChange notification doesn't try to re-serialise
        /// mid-edit (which would create a feedback loop).
        private var isApplyingProgrammaticEdit = false

        init(_ parent: MarkdownTextEditor) { self.parent = parent }

        /// Top-level entry point used by makeNSView + updateNSView
        /// when the source markdown changes externally. Replaces the
        /// storage with a freshly-rendered attributed string and then
        /// runs the inline-styling pass.
        func renderFullDocument(into tv: NSTextView, markdown: String) {
            guard let storage = tv.textStorage else { return }
            let fontSize = CGFloat(parent.appearance.fontSize)
            let rendered = NotesRenderer.render(markdown: markdown,
                                                fontSize: fontSize)
            isApplyingProgrammaticEdit = true
            storage.beginEditing()
            storage.setAttributedString(rendered)
            storage.endEditing()
            isApplyingProgrammaticEdit = false
            lastRenderedSource = markdown
            applyInlineStyling(to: tv)
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingProgrammaticEdit,
                  let tv = notification.object as? NSTextView,
                  let storage = tv.textStorage else { return }
            // Serialise: walk the storage, attachments contribute
            // their sourceMarkdown, plain chars pass through. Push
            // into the binding so backup, search, FTS see the
            // up-to-date source.
            let markdown = NotesRenderer.serialise(storage: storage)
            lastRenderedSource = markdown
            parent.text = markdown
            // Reset cached caret line so the next selection change
            // forces a clean re-paint — text edits can shift ranges.
            lastCaretLineRange = NSRange(location: NSNotFound, length: 0)
            applyInlineStyling(to: tv)
        }

        /// Re-paint when the caret crosses a line boundary — that's the
        /// trigger for showing / hiding inline syntax markers.
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            let lineRange = caretLineRange(in: tv)
            if !NSEqualRanges(lineRange, lastCaretLineRange) {
                lastCaretLineRange = lineRange
                applyInlineStyling(to: tv)
            }
        }

        /// Apply inline-only styling (bold, italic, headings,
        /// hashtags, wiki-links, code, strikethrough, highlight,
        /// footnotes, fenced code blocks, blockquotes). Atomic
        /// elements (checkbox / bullet / image / table) are already
        /// represented as NSTextAttachments in storage — the renderer
        /// handles them; the inline pass only walks plain-text ranges.
        func applyInlineStyling(to tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            let full = NSRange(location: 0, length: (tv.string as NSString).length)
            isApplyingProgrammaticEdit = true
            storage.beginEditing()
            // Reset attributes on plain-text ranges only, leaving
            // attachment ranges untouched (their styling is owned by
            // the NSTextAttachment subclass).
            let baseSize = CGFloat(parent.appearance.fontSize)
            let baseFont = parent.appearance.font.baseFont(size: baseSize)
            let base: [NSAttributedString.Key: Any] = [
                .font: baseFont,
                .foregroundColor: NSColor(parent.appearance.theme.text),
            ]
            forEachPlainTextRange(in: storage, full: full) { range in
                storage.setAttributes(base, range: range)
            }

            let caretLine = caretLineRange(in: tv)
            let source = tv.string

            // 1. Inline token styling — bold, italic, headings, etc.
            //    NoteTokenizer matches on actual characters, so the
            //    U+FFFC attachment placeholders never trigger a
            //    spurious match.
            for (range, kind) in NoteTokenizer.highlightRanges(in: source) {
                guard range.location >= 0,
                      range.location + range.length <= full.length else { continue }
                storage.addAttributes(attributes(for: kind), range: range)
                applySyntaxMarkerStyling(kind: kind,
                                         range: range,
                                         storage: storage,
                                         source: source,
                                         caretLine: caretLine)
            }

            // 2. Block-level styling (code blocks + blockquotes
            //    that didn't get captured by atomic-element passes).
            applyCodeBlockStyling(storage: storage, source: source)
            applyBlockquoteStyling(storage: storage, source: source, caretLine: caretLine)

            storage.endEditing()
            isApplyingProgrammaticEdit = false
        }

        /// Enumerate the maximal sub-ranges of `full` that contain no
        /// attachment characters. Used by the styling pass so we
        /// don't blow away an attachment's run via setAttributes.
        private func forEachPlainTextRange(in storage: NSAttributedString,
                                           full: NSRange,
                                           body: (NSRange) -> Void) {
            let ns = storage.string as NSString
            var rangeStart = full.location
            var i = full.location
            let end = full.location + full.length
            while i < end {
                if ns.character(at: i) == 0xFFFC {
                    if i > rangeStart {
                        body(NSRange(location: rangeStart, length: i - rangeStart))
                    }
                    rangeStart = i + 1
                }
                i += 1
            }
            if rangeStart < end {
                body(NSRange(location: rangeStart, length: end - rangeStart))
            }
        }

        // MARK: - Caret tracking

        /// Range of the line containing the (primary) selection. Used
        /// to decide whether to show syntax markers on a given line.
        private func caretLineRange(in tv: NSTextView) -> NSRange {
            let ns = tv.string as NSString
            let sel = tv.selectedRange()
            // selectedRange().location can sit at end-of-string (>= length).
            let loc = min(sel.location, max(0, ns.length - 1))
            guard ns.length > 0 else {
                return NSRange(location: 0, length: 0)
            }
            return ns.lineRange(for: NSRange(location: loc, length: 0))
        }

        // MARK: - Token attributes

        private func attributes(for kind: NoteTokenizer.TokenKind)
        -> [NSAttributedString.Key: Any] {
            let baseSize = CGFloat(parent.appearance.fontSize)
            let theme = parent.appearance.theme
            let chosen = parent.appearance.font
            let baseFont = chosen.baseFont(size: baseSize)
            switch kind {
            case .tag:
                return [
                    .foregroundColor: NSColor(theme.accent),
                    .font: weighted(baseFont, .medium),
                ]
            case .wikiLink:
                return [
                    .foregroundColor: NSColor(theme.accent),
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ]
            case .bold:
                return [ .font: weighted(baseFont, .semibold) ]
            case .emphasis:
                let italic = NSFontManager.shared.convert(baseFont,
                                                          toHaveTrait: .italicFontMask)
                return [ .font: italic ]
            case .code:
                return [
                    .font: NSFont.monospacedSystemFont(ofSize: baseSize - 1, weight: .regular),
                    .foregroundColor: NSColor(theme.accent),
                ]
            case .heading:
                return [
                    .font: weighted(baseFont, .bold),
                    .foregroundColor: NSColor(theme.text),
                ]
            case .strikethrough:
                return [
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .foregroundColor: NSColor(theme.muted),
                ]
            case .highlight:
                return [
                    .backgroundColor: NSColor(theme.accent).withAlphaComponent(0.25),
                ]
            case .footnoteRef:
                // Render as small accent superscript: smaller font +
                // baseline offset + accent colour.
                return [
                    .font: NSFont.systemFont(ofSize: max(8, baseSize - 4), weight: .medium),
                    .foregroundColor: NSColor(theme.accent),
                    .baselineOffset: 4 as NSNumber,
                ]
            }
        }

        /// Return `font` with `weight` applied while preserving the
        /// family (so swapping the user's pick between serif and
        /// system still produces a bold-in-the-same-family).
        private func weighted(_ font: NSFont, _ weight: NSFont.Weight) -> NSFont {
            let descriptor = font.fontDescriptor
                .addingAttributes([
                    .traits: [NSFontDescriptor.TraitKey.weight: weight]
                ])
            return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
        }

        /// Apply per-token "syntax marker" styling. Two modes:
        ///
        ///   - **Caret line**: markers dimmed to 55% muted but visible.
        ///   - **Other lines**: markers fully hidden (`.clear`). This
        ///     is what creates Bear's WYSIWYG-feeling output without
        ///     building a full block-rendering engine.
        ///
        /// Also bumps the inner font size for headings based on `#` count.
        private func applySyntaxMarkerStyling(kind: NoteTokenizer.TokenKind,
                                              range: NSRange,
                                              storage: NSTextStorage,
                                              source: String,
                                              caretLine: NSRange) {
            let onCaretLine = NSIntersectionRange(range, caretLine).length > 0
            let theme = parent.appearance.theme
            let markerColor: NSColor = onCaretLine
                ? NSColor(theme.muted).withAlphaComponent(0.55)
                : .clear

            switch kind {
            case .bold:
                guard range.length > 4 else { return }
                styleMarker(storage, NSRange(location: range.location, length: 2), markerColor)
                styleMarker(storage,
                            NSRange(location: range.location + range.length - 2, length: 2),
                            markerColor)
            case .emphasis, .code:
                guard range.length > 2 else { return }
                styleMarker(storage, NSRange(location: range.location, length: 1), markerColor)
                styleMarker(storage,
                            NSRange(location: range.location + range.length - 1, length: 1),
                            markerColor)
            case .wikiLink, .strikethrough, .highlight:
                // 2-char paired delimiters on both ends: `[[ ]]`,
                // `~~ ~~`, `== ==`. All look identical syntactically.
                guard range.length > 4 else { return }
                styleMarker(storage, NSRange(location: range.location, length: 2), markerColor)
                styleMarker(storage,
                            NSRange(location: range.location + range.length - 2, length: 2),
                            markerColor)
            case .heading:
                let ns = source as NSString
                var hashes = 0
                while hashes < range.length,
                      ns.character(at: range.location + hashes) == UInt16(("#" as Character).asciiValue!),
                      hashes < 6 {
                    hashes += 1
                }
                guard hashes > 0 else { return }
                let markerLen = min(hashes + 1, range.length)
                let baseSize = CGFloat(parent.appearance.fontSize)
                let pointSize: CGFloat = {
                    switch hashes {
                    case 1: return baseSize * 1.55
                    case 2: return baseSize * 1.30
                    case 3: return baseSize * 1.15
                    default: return baseSize
                    }
                }()
                let inner = NSRange(location: range.location + markerLen,
                                    length: range.length - markerLen)
                if inner.length > 0 {
                    let baseFont = parent.appearance.font.baseFont(size: pointSize)
                    let bold = NSFontManager.shared.convert(baseFont,
                                                            toHaveTrait: .boldFontMask)
                    storage.addAttribute(.font, value: bold, range: inner)
                }
                styleMarker(storage,
                            NSRange(location: range.location, length: markerLen),
                            markerColor)
            default:
                break
            }
        }

        private func styleMarker(_ storage: NSTextStorage,
                                 _ range: NSRange,
                                 _ color: NSColor) {
            storage.addAttribute(.foregroundColor, value: color, range: range)
        }

        // MARK: - Block-level styling

        /// Fenced code blocks — every line between ``` markers gets
        /// monospace font and a muted background colour. The fence
        /// lines themselves dim like regular syntax markers.
        private func applyCodeBlockStyling(storage: NSTextStorage, source: String) {
            let ns = source as NSString
            // Find ```...``` blocks. Naive line-by-line scan — fast and
            // tolerant of malformed open/close pairs (unmatched fence
            // styles the rest of the buffer, which the user can fix).
            var inBlock = false
            var blockStart = 0
            var lineStart = 0
            while lineStart < ns.length {
                let lineRange = ns.lineRange(for: NSRange(location: lineStart, length: 0))
                let lineText = ns.substring(with: lineRange)
                let trimmed = lineText.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("```") {
                    if inBlock {
                        // Closing fence — style the whole block.
                        let blockRange = NSRange(location: blockStart,
                                                 length: lineRange.location + lineRange.length - blockStart)
                        styleCodeBlock(storage: storage, range: blockRange)
                        inBlock = false
                    } else {
                        // Opening fence.
                        inBlock = true
                        blockStart = lineRange.location
                    }
                }
                lineStart = lineRange.location + lineRange.length
            }
            // Unterminated block — still style what we have so the
            // visual shape is clear as the user types.
            if inBlock {
                let blockRange = NSRange(location: blockStart, length: ns.length - blockStart)
                styleCodeBlock(storage: storage, range: blockRange)
            }
        }

        private func styleCodeBlock(storage: NSTextStorage, range: NSRange) {
            let baseSize = CGFloat(parent.appearance.fontSize)
            let mono = NSFont.monospacedSystemFont(ofSize: baseSize - 1, weight: .regular)
            storage.addAttribute(.font, value: mono, range: range)
            // Code-block background uses TallyTheme.codeSurface in
            // system mode (which is what most users will be on); the
            // sepia/dark-contrast themes don't currently override it,
            // and the default reads acceptably against both.
            storage.addAttribute(.backgroundColor,
                                 value: NSColor(TallyTheme.codeSurface),
                                 range: range)
        }

        /// Blockquotes — lines starting with `> ` get a paragraph style
        /// with a head indent so the text sits inside a left-bar
        /// gutter, plus muted foreground. The `> ` marker itself is
        /// dimmed (or fully hidden on non-caret lines, same convention
        /// as the inline syntax markers).
        private func applyBlockquoteStyling(storage: NSTextStorage,
                                            source: String,
                                            caretLine: NSRange) {
            let ns = source as NSString
            let theme = parent.appearance.theme
            var lineStart = 0
            while lineStart < ns.length {
                let lineRange = ns.lineRange(for: NSRange(location: lineStart, length: 0))
                let lineText = ns.substring(with: lineRange)
                // Find leading whitespace + `> `.
                let trimmedLeading = lineText.drop { $0 == " " || $0 == "\t" }
                let leadingCount = lineText.count - trimmedLeading.count
                if trimmedLeading.hasPrefix("> ") {
                    let style = NSMutableParagraphStyle()
                    style.headIndent = 16
                    style.firstLineHeadIndent = 16
                    storage.addAttribute(.paragraphStyle, value: style, range: lineRange)
                    storage.addAttribute(.foregroundColor,
                                         value: NSColor(theme.muted),
                                         range: lineRange)
                    // Dim / hide the `> ` marker per cursor-aware rule.
                    let onCaretLine = NSIntersectionRange(lineRange, caretLine).length > 0
                    let markerColor: NSColor = onCaretLine
                        ? NSColor(theme.muted).withAlphaComponent(0.55)
                        : .clear
                    let markerRange = NSRange(location: lineRange.location + leadingCount,
                                              length: 2)
                    if markerRange.location + markerRange.length <= ns.length {
                        storage.addAttribute(.foregroundColor,
                                             value: markerColor,
                                             range: markerRange)
                    }
                }
                lineStart = lineRange.location + lineRange.length
            }
        }

        /// Round-trip the current storage back to markdown and push
        /// into the @Binding text. Called when an attachment mutates
        /// in place (e.g. checkbox toggle) — the storage's character
        /// contents don't change, so textDidChange doesn't fire, but
        /// the serialised markdown does.
        func syncBindingFromStorage(in tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            let markdown = NotesRenderer.serialise(storage: storage)
            lastRenderedSource = markdown
            parent.text = markdown
        }

        // MARK: - Autocomplete (hashtags + wiki-links)

        /// Returns true if the caret is inside a token that has live
        /// autocomplete. Used by NotesEditorTextView to decide whether
        /// to call `complete(nil)` after a keystroke.
        func shouldOfferCompletions(after _: String, in textView: NSTextView) -> Bool {
            return currentCompletionContext(in: textView) != nil
        }

        private enum CompletionContext {
            case hashtag(query: String, range: NSRange)
            case wikiLink(query: String, range: NSRange)
        }

        private func currentCompletionContext(in textView: NSTextView) -> CompletionContext? {
            let ns = textView.string as NSString
            let caret = textView.selectedRange().location
            guard caret > 0 else { return nil }
            if let wikiCtx = scanWikiLinkContext(ns: ns, caret: caret) {
                return wikiCtx
            }
            if let tagCtx = scanHashtagContext(ns: ns, caret: caret) {
                return tagCtx
            }
            return nil
        }

        private func scanHashtagContext(ns: NSString, caret: Int) -> CompletionContext? {
            var i = caret - 1
            while i >= 0 {
                let ch = ns.character(at: i)
                if ch == UInt16(("#" as Character).asciiValue!) {
                    if i > 0 {
                        let prev = ns.character(at: i - 1)
                        let ok = prev == UInt16(("\n" as Character).asciiValue!)
                            || prev == UInt16((" " as Character).asciiValue!)
                            || prev == UInt16(("\t" as Character).asciiValue!)
                        guard ok else { return nil }
                    }
                    let queryRange = NSRange(location: i + 1, length: caret - i - 1)
                    let query = ns.substring(with: queryRange)
                    return .hashtag(query: query, range: queryRange)
                }
                if !isHashtagChar(ch) { return nil }
                i -= 1
            }
            return nil
        }

        private func isHashtagChar(_ ch: unichar) -> Bool {
            (ch >= 0x30 && ch <= 0x39) ||
            (ch >= 0x41 && ch <= 0x5A) ||
            (ch >= 0x61 && ch <= 0x7A) ||
            ch == UInt16(("_" as Character).asciiValue!) ||
            ch == UInt16(("-" as Character).asciiValue!) ||
            ch == UInt16(("/" as Character).asciiValue!)
        }

        private func scanWikiLinkContext(ns: NSString, caret: Int) -> CompletionContext? {
            let lookbackStart = max(0, caret - 200)
            var i = caret - 1
            while i >= lookbackStart {
                let ch = ns.character(at: i)
                if ch == UInt16(("]" as Character).asciiValue!)
                    || ch == UInt16(("\n" as Character).asciiValue!) {
                    return nil
                }
                if ch == UInt16(("[" as Character).asciiValue!) {
                    if i - 1 >= 0,
                       ns.character(at: i - 1) == UInt16(("[" as Character).asciiValue!) {
                        let queryStart = i + 1
                        let queryRange = NSRange(location: queryStart,
                                                 length: caret - queryStart)
                        let query = ns.substring(with: queryRange)
                        return .wikiLink(query: query, range: queryRange)
                    }
                    return nil
                }
                i -= 1
            }
            return nil
        }

        // NSTextView completion delegate hook. Apple's bridged
        // signature uses optional `UnsafeMutablePointer<Int>?` and
        // optional `[String]?` — nil/empty either dismisses the popover.
        func textView(_ textView: NSTextView,
                      completions words: [String],
                      forPartialWordRange charRange: NSRange,
                      indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
            guard let ctx = currentCompletionContext(in: textView) else { return [] }
            switch ctx {
            case .hashtag(let query, _):
                guard let provider = parent.controller.fetchTagSuggestions else { return [] }
                let q = query.lowercased()
                return Array(provider(query)
                    .filter { q.isEmpty || $0.lowercased().hasPrefix(q) }
                    .prefix(10))
            case .wikiLink(let query, _):
                guard let provider = parent.controller.fetchTitleSuggestions else { return [] }
                let q = query.lowercased()
                return Array(provider(query)
                    .filter { q.isEmpty || $0.lowercased().contains(q) }
                    .prefix(10))
            }
        }

        // Custom insert-completion: for wiki-links, also append the
        // closing `]]` so the user doesn't have to type it.
        func textView(_ textView: NSTextView,
                      insertCompletion word: String,
                      forPartialWordRange charRange: NSRange,
                      movement: Int,
                      isFinal flag: Bool) {
            guard flag else { return }
            guard let ctx = currentCompletionContext(in: textView) else {
                textView.replaceCharacters(in: charRange, with: word)
                return
            }
            switch ctx {
            case .hashtag(_, let range):
                textView.replaceCharacters(in: range, with: word)
                let newCaret = range.location + (word as NSString).length
                textView.selectedRange = NSRange(location: newCaret, length: 0)
            case .wikiLink(_, let range):
                let replacement = "\(word)]]"
                textView.replaceCharacters(in: range, with: replacement)
                let newCaret = range.location + (replacement as NSString).length
                textView.selectedRange = NSRange(location: newCaret, length: 0)
            }
        }

        // MARK: - Paste

        func handlePaste(in textView: NSTextView) -> Bool {
            let pb = NSPasteboard.general
            let types: [NSPasteboard.PasteboardType] = [.png, .tiff, .fileURL]
            guard let available = pb.availableType(from: types) else { return false }
            let image: NSImage? = {
                switch available {
                case .fileURL:
                    guard let urlStr = pb.string(forType: .fileURL),
                          let url = URL(string: urlStr),
                          ["png","jpg","jpeg","tiff","heic","gif"]
                            .contains(url.pathExtension.lowercased()) else { return nil }
                    return NSImage(contentsOf: url)
                default:
                    return NSImage(pasteboard: pb)
                }
            }()
            guard let image else { return false }
            do {
                let assetURL = try NotesAssets.saveImage(image)
                // Insert the image as a real attachment at the
                // caret. The attachment knows its sourceMarkdown so
                // the storage→markdown serialiser produces a clean
                // `![](notes-asset://...)` token on save.
                let attachment = InlineImageAttachment(
                    assetURLString: assetURL.absoluteString,
                    altText: "",
                    maxWidth: 360)
                let attachmentString = NSAttributedString(attachment: attachment)
                let selected = textView.selectedRange()
                if textView.shouldChangeText(in: selected,
                                             replacementString: attachmentString.string) {
                    textView.textStorage?.replaceCharacters(in: selected,
                                                             with: attachmentString)
                    textView.didChangeText()
                    let newLoc = selected.location + 1
                    textView.selectedRange = NSRange(location: newLoc, length: 0)
                }
                return true
            } catch {
                return false
            }
        }

        // MARK: - Slash commands

        /// After a space is typed, look backward from the caret for a
        /// `/keyword ` pattern at line start or after whitespace and
        /// expand it into the matching markdown shape. This is the
        /// lightweight version of Bear's `/` command palette — no
        /// popover, just snippet-style inline replacement on Space.
        func tryExpandSlashCommand(in textView: NSTextView) {
            let ns = textView.string as NSString
            let caret = textView.selectedRange().location
            // We were called *after* inserting a space, so the chars at
            // caret-1 is the trailing space. Scan back from there for `/`.
            guard caret >= 2 else { return }
            // Find the most-recent `/` before the caret on the same line.
            let lineStart = ns.lineRange(for: NSRange(location: caret - 1, length: 0)).location
            var i = caret - 2   // last non-space character before caret
            var slashLoc = -1
            while i >= lineStart {
                let ch = ns.character(at: i)
                if ch == UInt16(("/" as Character).asciiValue!) {
                    slashLoc = i
                    break
                }
                // Stop if we hit a non-word char that's not the slash.
                if !isSlashCommandChar(ch) { return }
                i -= 1
            }
            guard slashLoc >= 0 else { return }
            // The `/` must be at line start or after a whitespace char,
            // so we don't swallow `http://` etc.
            if slashLoc > lineStart {
                let prev = ns.character(at: slashLoc - 1)
                let prevIsBoundary = prev == UInt16((" " as Character).asciiValue!)
                    || prev == UInt16(("\t" as Character).asciiValue!)
                guard prevIsBoundary else { return }
            }
            let keywordRange = NSRange(location: slashLoc + 1,
                                       length: caret - 1 - (slashLoc + 1))
            guard keywordRange.length > 0 else { return }
            let keyword = ns.substring(with: keywordRange).lowercased()
            guard let expansion = SlashCommand.expansion(for: keyword) else { return }
            // Replace `/keyword ` (including the trailing space) with
            // the expansion, then place the caret at the desired offset.
            let fullRange = NSRange(location: slashLoc, length: caret - slashLoc)
            if textView.shouldChangeText(in: fullRange,
                                         replacementString: expansion.text) {
                textView.replaceCharacters(in: fullRange, with: expansion.text)
                textView.didChangeText()
                let endLoc = slashLoc + (expansion.text as NSString).length
                let caretLoc = endLoc - expansion.caretOffsetFromEnd
                textView.selectedRange = NSRange(location: caretLoc, length: 0)
            }
        }

        private func isSlashCommandChar(_ ch: unichar) -> Bool {
            (ch >= 0x30 && ch <= 0x39) ||   // 0-9
            (ch >= 0x41 && ch <= 0x5A) ||   // A-Z
            (ch >= 0x61 && ch <= 0x7A) ||   // a-z
            ch == UInt16(("_" as Character).asciiValue!) ||
            ch == UInt16(("-" as Character).asciiValue!)
        }

        // MARK: - List auto-continue (called from NotesEditorTextView)

        /// On Return key inside a list item, repeat the item's prefix
        /// on the new line. On Return inside an *empty* list item,
        /// strip the prefix and exit the list — Bear / iA Writer /
        /// Obsidian standard behaviour.
        ///
        /// Returns true if we handled the event; false to let NSTextView
        /// insert a plain newline.
        func handleReturn(in textView: NSTextView) -> Bool {
            let ns = textView.string as NSString
            let sel = textView.selectedRange()
            let lineRange = ns.lineRange(for: NSRange(location: sel.location, length: 0))
            let lineText = ns.substring(with: lineRange)
            // Strip trailing newline for matching.
            let lineNoNewline = lineText.hasSuffix("\n")
                ? String(lineText.dropLast())
                : lineText
            guard let (prefix, isEmpty) = listPrefix(of: lineNoNewline) else {
                return false
            }
            if isEmpty {
                // Empty list item — replace the whole line with a
                // single newline, exiting the list.
                let replaceRange = NSRange(location: lineRange.location,
                                           length: lineNoNewline.count)
                if textView.shouldChangeText(in: replaceRange, replacementString: "") {
                    textView.replaceCharacters(in: replaceRange, with: "")
                    textView.didChangeText()
                    textView.insertNewline(nil)
                }
                return true
            }
            // Continue list: newline + same prefix.
            let nextPrefix = nextListPrefix(after: prefix)
            let insertion = "\n" + nextPrefix
            if textView.shouldChangeText(in: sel, replacementString: insertion) {
                textView.replaceCharacters(in: sel, with: insertion)
                textView.didChangeText()
                let newCaret = sel.location + (insertion as NSString).length
                textView.selectedRange = NSRange(location: newCaret, length: 0)
            }
            return true
        }

        /// Return the list-item prefix of a line, and whether the line
        /// has *only* the prefix (i.e. an empty list item, signalling
        /// the user wants to exit the list on next Return).
        private func listPrefix(of line: String) -> (prefix: String, isEmpty: Bool)? {
            // Indented prefix support: keep the leading whitespace, then
            // match the bullet shape, then the (possibly empty) body.
            let pattern = #"^([ \t]*)(- \[ \] |- \[x\] |- \[X\] |[-*+] |\d+\. )(.*)$"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            let ns = line as NSString
            let r = NSRange(location: 0, length: ns.length)
            guard let m = regex.firstMatch(in: line, range: r),
                  m.numberOfRanges >= 4 else { return nil }
            let indent = ns.substring(with: m.range(at: 1))
            let marker = ns.substring(with: m.range(at: 2))
            let body = ns.substring(with: m.range(at: 3))
            return (indent + marker, body.trimmingCharacters(in: .whitespaces).isEmpty)
        }

        /// For numbered list items, increment the number on the next
        /// line. For bullets / checkboxes, return the prefix unchanged
        /// (with checkboxes always returning an *unchecked* `[ ]`).
        private func nextListPrefix(after prefix: String) -> String {
            // Numbered: `<indent>N. ` → `<indent>(N+1). `
            let pattern = #"^([ \t]*)(\d+)(\. )$"#
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let ns = prefix as NSString
                let r = NSRange(location: 0, length: ns.length)
                if let m = regex.firstMatch(in: prefix, range: r),
                   m.numberOfRanges >= 4 {
                    let indent = ns.substring(with: m.range(at: 1))
                    let n = Int(ns.substring(with: m.range(at: 2))) ?? 1
                    let tail = ns.substring(with: m.range(at: 3))
                    return "\(indent)\(n + 1)\(tail)"
                }
            }
            // Checkbox: always insert an *un*-checked next item, even
            // if the previous one was checked.
            if prefix.contains("[x]") || prefix.contains("[X]") {
                return prefix
                    .replacingOccurrences(of: "[x]", with: "[ ]")
                    .replacingOccurrences(of: "[X]", with: "[ ]")
            }
            return prefix
        }

        // (Checkbox toggle is now handled by the attachment
        // mutating its `checked` flag in place — see
        // NotesEditorTextView.mouseDown + syncBindingFromStorage.)
    }
}

private extension Array {
    /// Out-of-bounds index returns nil rather than crashing — keeps
    /// the table renderer tolerant of ragged rows (a markdown table
    /// with a row that has fewer cells than the header).
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// Inline slash-command snippets. Typing `/<keyword> ` at a line start
/// (or after whitespace) is replaced with the corresponding markdown
/// shape. Bear's `/` command palette in spirit; simpler in mechanics
/// (no popover, no fuzzy match) — fast to type once memorised.
enum SlashCommand {
    struct Expansion {
        let text: String
        /// How many characters back from end the caret should land. 0
        /// = caret at end of expansion.
        let caretOffsetFromEnd: Int
    }

    static func expansion(for keyword: String) -> Expansion? {
        switch keyword {
        case "h1":         return Expansion(text: "# ", caretOffsetFromEnd: 0)
        case "h2":         return Expansion(text: "## ", caretOffsetFromEnd: 0)
        case "h3":         return Expansion(text: "### ", caretOffsetFromEnd: 0)
        case "list", "ul": return Expansion(text: "- ", caretOffsetFromEnd: 0)
        case "num", "ol":  return Expansion(text: "1. ", caretOffsetFromEnd: 0)
        case "todo":       return Expansion(text: "- [ ] ", caretOffsetFromEnd: 0)
        case "quote":      return Expansion(text: "> ", caretOffsetFromEnd: 0)
        case "code":
            // Caret lands inside the fence so user can type the code
            // immediately.
            return Expansion(text: "```\n\n```", caretOffsetFromEnd: 4)
        case "divider", "hr":
            return Expansion(text: "---\n", caretOffsetFromEnd: 0)
        case "table":
            let template = """
            | Column 1 | Column 2 |
            | -------- | -------- |
            |          |          |

            """
            // Caret lands inside the first header cell.
            let toEnd = template.count - 2   // after "| "
            return Expansion(text: template, caretOffsetFromEnd: template.count - toEnd)
        default:
            return nil
        }
    }
}

/// NSTextView subclass: image-paste interception, list auto-continue,
/// and checkbox click toggle.
final class NotesEditorTextView: NSTextView {
    weak var coordinator: MarkdownTextEditor.Coordinator?

    override func paste(_ sender: Any?) {
        if let coordinator, coordinator.handlePaste(in: self) {
            return
        }
        super.paste(sender)
    }

    /// Trigger slash-command expansion + autocomplete after specific
    /// characters land. Has to be after `super.insertText` so the
    /// inserted character is already in the buffer when we scan.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        guard let s = string as? String else { return }
        if s == " " {
            coordinator?.tryExpandSlashCommand(in: self)
        }
        if s == "#" || s == "[" || (s.count == 1 && coordinator?.shouldOfferCompletions(after: s, in: self) == true) {
            // Auto-trigger the system completion popover when we're
            // inside a hashtag or wiki-link token. Cheap to call —
            // NSTextView dismisses immediately if the delegate returns
            // no completions.
            complete(nil)
        }
    }

    /// Return key — let the coordinator decide whether we're in a list
    /// context. If so, it handles the insertion itself and we no-op;
    /// otherwise we fall through to NSTextView's default newline.
    override func insertNewline(_ sender: Any?) {
        if let coordinator, coordinator.handleReturn(in: self) {
            return
        }
        super.insertNewline(sender)
    }

    // (Overlay-based drawing for checkbox / bullet / table is gone —
    // atomic elements are real NSTextAttachments now and render
    // themselves through the layout manager. See NotesAttachments.swift.)


    /// Click on a checkbox attachment → toggle its `checked` state and
    /// trigger a redraw. The attachment is mutable; the storage
    /// observers see the change via `processEditing` on the layout
    /// manager when we explicitly invalidate display for the
    /// attachment's range.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let containerOffset = textContainerOrigin
        let inContainer = NSPoint(x: point.x - containerOffset.x,
                                  y: point.y - containerOffset.y)
        if let layoutManager,
           let textContainer,
           let storage = textStorage {
            let glyphIndex = layoutManager.glyphIndex(for: inContainer,
                                                     in: textContainer)
            let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
            if charIndex < storage.length,
               let checkbox = storage.attribute(.attachment,
                                                at: charIndex,
                                                effectiveRange: nil) as? CheckboxAttachment {
                checkbox.checked.toggle()
                // Invalidate the cell so the image is re-pulled.
                let range = NSRange(location: charIndex, length: 1)
                layoutManager.invalidateDisplay(forCharacterRange: range)
                // The storage didn't structurally change, but the
                // serialised markdown did (`[ ]` ↔ `[x]`). Push the
                // new source through the binding so backup/FTS pick
                // it up.
                coordinator?.syncBindingFromStorage(in: self)
                return
            }
        }
        super.mouseDown(with: event)
    }
}
