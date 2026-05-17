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
        textView.font = .systemFont(ofSize: 14)
        textView.backgroundColor = NSColor(TallyTheme.background)
        textView.drawsBackground = true
        textView.textColor = NSColor(TallyTheme.text)
        textView.insertionPointColor = NSColor(TallyTheme.accent)

        textView.string = text
        context.coordinator.applyHighlighting(to: textView)
        controller.textView = textView
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NotesEditorTextView else { return }
        controller.textView = textView
        if textView.string != text {
            let selected = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selected
            context.coordinator.applyHighlighting(to: textView)
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: MarkdownTextEditor
        /// Last caret-line range we re-painted for; lets us skip the
        /// re-highlight pass when the user is typing within the same
        /// line (selection changes constantly but the *line* doesn't).
        private var lastCaretLineRange: NSRange = NSRange(location: NSNotFound, length: 0)

        init(_ parent: MarkdownTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            // Reset the cached line so the next selection change forces
            // a clean re-paint — text edits can shift line ranges.
            lastCaretLineRange = NSRange(location: NSNotFound, length: 0)
            applyHighlighting(to: tv)
        }

        /// Re-paint when the caret crosses a line boundary — that's the
        /// trigger for showing / hiding syntax markers.
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            let lineRange = caretLineRange(in: tv)
            if !NSEqualRanges(lineRange, lastCaretLineRange) {
                lastCaretLineRange = lineRange
                applyHighlighting(to: tv)
            }
        }

        /// Apply inline styling. Runs over the full text on every change
        /// — acceptable for typical note sizes. Two passes: token style,
        /// then syntax-marker dimming/hiding based on the current line.
        func applyHighlighting(to tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            let full = NSRange(location: 0, length: (tv.string as NSString).length)
            storage.beginEditing()
            // Base attributes — reset every run so we don't accumulate
            // stale styles from removed tokens.
            let base: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14),
                .foregroundColor: NSColor(TallyTheme.text),
            ]
            storage.setAttributes(base, range: full)

            let caretLine = caretLineRange(in: tv)
            let source = tv.string

            // 1. Token styling — bold, italic, headings, etc.
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

            // 2. Block-level rendering.
            applyCodeBlockStyling(storage: storage, source: source)
            applyBlockquoteStyling(storage: storage, source: source)

            // 3. Interactive checkboxes — replace `[ ]` / `[x]` with
            //    SF Symbol attachments. Done before image attachments
            //    so the checkbox is processed within the line.
            for cb in checkboxRanges(in: source) {
                applyCheckboxAttachment(storage: storage, range: cb.markerRange, checked: cb.checked)
            }

            // 4. Inline images.
            for imageRange in inlineImageRanges(in: source) {
                applyImageAttachment(storage: storage, range: imageRange, source: source)
            }
            storage.endEditing()
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
            switch kind {
            case .tag:
                return [
                    .foregroundColor: NSColor(TallyTheme.accent),
                    .font: NSFont.systemFont(ofSize: 14, weight: .medium),
                ]
            case .wikiLink:
                return [
                    .foregroundColor: NSColor(TallyTheme.accent),
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ]
            case .bold:
                return [ .font: NSFont.systemFont(ofSize: 14, weight: .semibold) ]
            case .emphasis:
                let italic = NSFontManager.shared.convert(
                    NSFont.systemFont(ofSize: 14),
                    toHaveTrait: .italicFontMask
                )
                return [ .font: italic ]
            case .code:
                return [
                    .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                    .foregroundColor: NSColor(TallyTheme.accent),
                ]
            case .heading:
                return [
                    .font: NSFont.boldSystemFont(ofSize: 14),
                    .foregroundColor: NSColor(TallyTheme.text),
                ]
            }
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
            let markerColor: NSColor = onCaretLine
                ? NSColor(TallyTheme.muted).withAlphaComponent(0.55)
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
            case .wikiLink:
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
                let pointSize: CGFloat = {
                    switch hashes {
                    case 1: return 22
                    case 2: return 18
                    case 3: return 16
                    default: return 14
                    }
                }()
                let inner = NSRange(location: range.location + markerLen,
                                    length: range.length - markerLen)
                if inner.length > 0 {
                    storage.addAttribute(.font,
                                         value: NSFont.boldSystemFont(ofSize: pointSize),
                                         range: inner)
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
            let mono = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            storage.addAttribute(.font, value: mono, range: range)
            storage.addAttribute(.backgroundColor,
                                 value: NSColor(TallyTheme.codeSurface),
                                 range: range)
        }

        /// Blockquotes — lines starting with `> ` get a paragraph style
        /// with a head indent so the text sits inside a left-bar gutter.
        /// The bar is drawn by the text storage's background colour on
        /// the leading 4pt of each line.
        private func applyBlockquoteStyling(storage: NSTextStorage, source: String) {
            let ns = source as NSString
            var lineStart = 0
            while lineStart < ns.length {
                let lineRange = ns.lineRange(for: NSRange(location: lineStart, length: 0))
                let lineText = ns.substring(with: lineRange)
                let trimmed = lineText.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("> ") {
                    let style = NSMutableParagraphStyle()
                    style.headIndent = 16
                    style.firstLineHeadIndent = 16
                    storage.addAttribute(.paragraphStyle, value: style, range: lineRange)
                    storage.addAttribute(.foregroundColor,
                                         value: NSColor(TallyTheme.muted),
                                         range: lineRange)
                }
                lineStart = lineRange.location + lineRange.length
            }
        }

        // MARK: - Checkboxes

        private struct CheckboxToken {
            let markerRange: NSRange   // covers exactly `[ ]` or `[x]`
            let checked: Bool
        }

        private func checkboxRanges(in source: String) -> [CheckboxToken] {
            // Match `- [ ]` / `- [x]` / `* [ ]` / `* [x]` at start of
            // line (allowing indent). The captured group is the box.
            let pattern = #"(?m)^[ \t]*[-*][ \t]+\[( |x|X)\]"#
            let ns = source as NSString
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            return regex.matches(in: source, range: NSRange(location: 0, length: ns.length))
                .compactMap { m in
                    guard m.numberOfRanges >= 2 else { return nil }
                    // m.range(at: 0) is the whole prefix incl. dash;
                    // we want just `[ ]` / `[x]`.
                    let fullRange = m.range(at: 0)
                    let innerRange = m.range(at: 1)
                    let boxRange = NSRange(location: innerRange.location - 1, length: 3)
                    let mark = ns.substring(with: innerRange).lowercased()
                    _ = fullRange
                    return CheckboxToken(markerRange: boxRange, checked: mark == "x")
                }
        }

        private func applyCheckboxAttachment(storage: NSTextStorage,
                                             range: NSRange,
                                             checked: Bool) {
            let symbol = checked ? "checkmark.square.fill" : "square"
            let tint = checked ? NSColor(TallyTheme.accent) : NSColor(TallyTheme.muted)
            let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(cfg) else { return }
            // Tint
            image.isTemplate = true
            let tinted = NSImage(size: image.size, flipped: false) { rect in
                tint.set()
                rect.fill()
                image.draw(in: rect, from: .zero,
                           operation: .destinationIn, fraction: 1.0)
                return true
            }
            let attachment = CheckboxAttachment(checked: checked)
            attachment.attachmentCell = NSTextAttachmentCell(imageCell: tinted)
            storage.addAttribute(.attachment, value: attachment, range: range)
            storage.addAttribute(.foregroundColor, value: NSColor.clear, range: range)
        }

        // MARK: - Inline images

        private func inlineImageRanges(in source: String) -> [NSRange] {
            let pattern = #"!\[[^\]]*\]\(notes-asset://[^)]+\)"#
            let ns = source as NSString
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            return regex.matches(in: source, range: NSRange(location: 0, length: ns.length))
                .map { $0.range }
        }

        private func applyImageAttachment(storage: NSTextStorage,
                                          range: NSRange,
                                          source: String) {
            let ns = source as NSString
            let span = ns.substring(with: range)
            guard let urlMatch = span.range(of: #"notes-asset://[^)]+"#,
                                            options: .regularExpression) else { return }
            let urlString = String(span[urlMatch])
            guard let url = URL(string: urlString),
                  let fileURL = NotesAssets.resolve(url),
                  let nsImage = NSImage(contentsOf: fileURL) else { return }

            let maxWidth: CGFloat = 360
            let originalSize = nsImage.size
            let scale = min(1.0, maxWidth / max(originalSize.width, 1))
            let display = NSSize(width: originalSize.width * scale,
                                 height: originalSize.height * scale)

            let resized = NSImage(size: display)
            resized.lockFocus()
            nsImage.draw(in: NSRect(origin: .zero, size: display),
                         from: NSRect(origin: .zero, size: originalSize),
                         operation: .sourceOver, fraction: 1.0)
            resized.unlockFocus()

            let attachment = NSTextAttachment()
            attachment.attachmentCell = NSTextAttachmentCell(imageCell: resized)
            storage.addAttribute(.attachment, value: attachment, range: range)
            storage.addAttribute(.foregroundColor, value: NSColor.clear, range: range)
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
                let snippet = "![](\(assetURL.absoluteString))"
                let selected = textView.selectedRange()
                let ns = textView.string as NSString
                let replaced = ns.replacingCharacters(in: selected, with: snippet)
                textView.string = replaced
                let newLoc = selected.location + (snippet as NSString).length
                textView.selectedRange = NSRange(location: newLoc, length: 0)
                parent.text = replaced
                applyHighlighting(to: textView)
                return true
            } catch {
                return false
            }
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

        // MARK: - Checkbox click handling

        /// Toggle the checkbox at the given character index. Called
        /// from `NotesEditorTextView.mouseDown(with:)` when the click
        /// lands on a CheckboxAttachment.
        func toggleCheckbox(at characterIndex: Int, in textView: NSTextView) {
            let ns = textView.string as NSString
            guard characterIndex >= 0, characterIndex + 3 <= ns.length else { return }
            let range = NSRange(location: characterIndex, length: 3)
            let current = ns.substring(with: range).lowercased()
            let replacement: String
            if current == "[ ]"        { replacement = "[x]" }
            else if current == "[x]"   { replacement = "[ ]" }
            else { return }
            if textView.shouldChangeText(in: range, replacementString: replacement) {
                textView.replaceCharacters(in: range, with: replacement)
                textView.didChangeText()
            }
        }
    }
}

/// NSTextAttachment subclass that carries the checkbox state. Used by
/// the NSTextView's mouseDown handler to find checkbox clicks (the
/// alternative — pattern-matching the underlying text after a click —
/// is fragile around layout-manager line-fragment math).
final class CheckboxAttachment: NSTextAttachment {
    let checked: Bool
    init(checked: Bool) {
        self.checked = checked
        super.init(data: nil, ofType: nil)
    }
    required init?(coder: NSCoder) {
        self.checked = false
        super.init(coder: coder)
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

    /// Return key — let the coordinator decide whether we're in a list
    /// context. If so, it handles the insertion itself and we no-op;
    /// otherwise we fall through to NSTextView's default newline.
    override func insertNewline(_ sender: Any?) {
        if let coordinator, coordinator.handleReturn(in: self) {
            return
        }
        super.insertNewline(sender)
    }

    /// Click on a checkbox attachment → toggle its state. Other clicks
    /// fall through to NSTextView for normal cursor placement.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let containerOffset = textContainerOrigin
        let inContainer = NSPoint(x: point.x - containerOffset.x,
                                  y: point.y - containerOffset.y)
        if let layoutManager,
           let textContainer {
            let glyphIndex = layoutManager.glyphIndex(for: inContainer,
                                                     in: textContainer)
            let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
            if charIndex < (string as NSString).length,
               let storage = textStorage {
                let attrs = storage.attributes(at: charIndex, effectiveRange: nil)
                if attrs[.attachment] is CheckboxAttachment {
                    coordinator?.toggleCheckbox(at: charIndex, in: self)
                    return
                }
            }
        }
        super.mouseDown(with: event)
    }
}
