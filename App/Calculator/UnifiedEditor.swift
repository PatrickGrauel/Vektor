import SwiftUI
import AppKit
import VektorEngine

/// Single-scroll editor + gutter, replacing the old HSplitView layout.
///
/// One NSScrollView is the only scrolling surface. Its documentView is
/// a `ColumnContainer` that holds three siblings: the editor's
/// NSTextView at the left, a 1pt `DividerStrip` in the middle (with
/// a 7pt invisible hit area for drag-resize), and a `GutterView` on
/// the right that draws the per-line results.
///
/// Because both columns live inside the same scroll surface, they
/// always scroll together row-for-row — no synchronisation logic,
/// no drift bug, no HSplitView divider chrome to hide.
///
/// Width is user-adjustable by dragging the divider; the chosen split
/// persists via `@AppStorage` at the call site.
struct UnifiedEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var editorWidth: CGFloat
    let results: [LineResult]
    let renderValue: (LineResult) -> NSAttributedString
    let renderAnnotation: (LineResult) -> NSAttributedString?
    /// Forwarded to the underlying NSTextView so `@reference` clicks
    /// can navigate to another document. Optional — when nil, clicks
    /// fall through to normal caret placement.
    var onPageReferenceClicked: ((String) -> Void)?
    /// Returns `true` when the given slug resolves to an existing
    /// document. Drives two-state styling for `@reference` tokens —
    /// resolved refs get the active accent + solid underline; unresolved
    /// refs render muted with a dotted underline so the user can tell
    /// "this won't navigate" at a glance, without making the @-syntax
    /// disappear into surrounding text. Also gates click navigation:
    /// unresolved refs fall through to default caret placement so the
    /// token is still text-editable.
    var resolvePageReference: (String) -> Bool = { _ in false }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(VektorTheme.background)
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        // The unified documentView. It owns layout for all three
        // columns and updates its own height to match the editor's
        // content (so the outer scroll view scrolls the whole thing).
        let column = ColumnContainer()
        column.translatesAutoresizingMaskIntoConstraints = true
        column.autoresizingMask = [.width]

        // 1. The editor — same AutocompletingTextView we've been using,
        //    just without its own enclosing scroll view this time. The
        //    outer NSScrollView is what scrolls.
        let tv = AutocompletingTextView()
        tv.onPageReferenceClicked = onPageReferenceClicked
        tv.resolvePageReference = resolvePageReference
        context.coordinator.resolvePageReference = resolvePageReference
        tv.isRichText = false
        tv.isEditable = true
        tv.isSelectable = true
        tv.allowsUndo = true
        tv.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        tv.textColor = NSColor(VektorTheme.text)
        tv.insertionPointColor = NSColor(VektorTheme.accent)
        tv.backgroundColor = NSColor(VektorTheme.background)
        tv.drawsBackground = true
        tv.delegate = context.coordinator
        tv.textContainerInset = NSSize(width: 18, height: 14)
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = true
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        tv.autoresizingMask = []
        if let container = tv.textContainer {
            container.lineFragmentPadding = 0
            container.widthTracksTextView = true
            container.heightTracksTextView = false
            container.containerSize = NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude)
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 18
        paragraph.maximumLineHeight = 18
        tv.defaultParagraphStyle = paragraph
        tv.typingAttributes = [
            .font: tv.font!,
            .foregroundColor: NSColor(VektorTheme.text),
            .paragraphStyle: paragraph,
        ]
        tv.string = text
        tv.textStorage?.delegate = context.coordinator
        if let storage = tv.textStorage {
            context.coordinator.applyLineColors(to: storage)
        }

        let divider = DividerStrip()
        divider.onDrag = { [weak column] delta in
            column?.dragDivider(by: delta)
        }
        divider.onDragEnd = { [weak column] in
            column?.commitDragEnd()
        }

        let gutter = GutterView()
        gutter.results = results
        gutter.renderValue = renderValue
        gutter.renderAnnotation = renderAnnotation

        column.editor = tv
        column.divider = divider
        column.gutter = gutter
        column.editorWidth = editorWidth
        column.onEditorWidthChange = { newWidth in
            DispatchQueue.main.async {
                if abs(self.editorWidth - newWidth) > 0.5 {
                    self.editorWidth = newWidth
                }
            }
        }
        column.addSubview(tv)
        column.addSubview(gutter)
        column.addSubview(divider)
        context.coordinator.column = column

        scroll.documentView = column
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let column = scroll.documentView as? ColumnContainer,
              let tv = column.editor
        else { return }

        // Keep the click-jump closure and slug resolver in sync with
        // SwiftUI re-renders — both can capture fresher state on each
        // body recomputation.
        tv.onPageReferenceClicked = onPageReferenceClicked
        tv.resolvePageReference = resolvePageReference
        context.coordinator.resolvePageReference = resolvePageReference

        // Text refresh (e.g. document switch).
        let textChanged = (tv.string != text)
        if textChanged {
            tv.string = text
            if let storage = tv.textStorage {
                context.coordinator.applyLineColors(to: storage)
            }
            // Reassigning `tv.string` wipes paragraph attributes back to
            // the defaultParagraphStyle, so any spacing the previous doc
            // had stamped is gone. Invalidate so the next layout pass
            // re-stamps even if the new extras dict happens to match.
            column.invalidateAppliedExtras()
        }

        // Capture results-changed BEFORE we overwrite gutter.results.
        // Required so the async briefing case (METAR / TAF / RWY data
        // arriving over seconds, each firing a re-evaluate that grows
        // the result text) re-stamps paragraph spacing as the rendered
        // height grows. Without this, the user types a line below the
        // briefing, line 0's spacing stays frozen at the height it had
        // when the first METAR cache hit came in, and the next line's
        // gutter content overlaps the rest of the briefing.
        let resultsChanged = (column.gutter?.results ?? []) != results

        // Pipe latest renderers + data into the gutter.
        column.gutter?.results = results
        column.gutter?.renderValue = renderValue
        column.gutter?.renderAnnotation = renderAnnotation

        // Width may have changed from the call site.
        let widthChanged = abs(column.editorWidth - editorWidth) > 0.5
        column.editorWidth = editorWidth

        // textDidChange already ran relayoutAndResize for the user's just-
        // completed keystroke. SwiftUI then re-renders because the binding
        // write echoed back — that second updateNSView would relayout the
        // same state. Skip it unless something else genuinely changed.
        let coord = context.coordinator
        let suppressed = coord.skipNextRelayout
        coord.skipNextRelayout = false

        if !suppressed || textChanged || widthChanged || resultsChanged {
            column.needsLayout = true
            column.relayoutAndResize()
        }
        tv.recomputeSuggestion()
    }

    func makeCoordinator() -> UnifiedCoordinator {
        UnifiedCoordinator(text: $text)
    }
}

// MARK: - Coordinator

final class UnifiedCoordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
    let text: Binding<String>
    weak var column: ColumnContainer?
    /// Set after `textDidChange` finishes its own relayoutAndResize so the
    /// SwiftUI-binding echo's redundant `updateNSView` can skip a second
    /// pass. Consumed (cleared) by `updateNSView`.
    var skipNextRelayout: Bool = false
    /// Slug → does-this-doc-exist check. Installed by `UnifiedEditor` on
    /// each render so the styling pass picks up newly-created or
    /// deleted documents on the next text edit.
    var resolvePageReference: (String) -> Bool = { _ in false }

    init(text: Binding<String>) {
        self.text = text
    }

    func textDidChange(_ notification: Notification) {
        guard let tv = notification.object as? AutocompletingTextView else { return }
        text.wrappedValue = tv.string
        tv.recomputeSuggestion()
        column?.relayoutAndResize()
        skipNextRelayout = true
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let tv = notification.object as? AutocompletingTextView else { return }
        tv.recomputeSuggestion()
    }

    /// Per-keystroke syntax highlighting, applied DURING the storage
    /// edit cycle so the new character lands with the right colour.
    /// Re-colors only the lines intersecting `editedRange` — for a
    /// typical edit that's 1–2 lines instead of the whole document,
    /// keeping keystroke cost O(1) regardless of doc size.
    func textStorage(_ textStorage: NSTextStorage,
                     didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange,
                     changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        applyLineColors(to: textStorage, in: editedRange)
    }

    /// Full-document colour pass. Used for the initial render and for
    /// bulk text replacements (document switch) where the storage
    /// delegate path doesn't fire on a per-line basis.
    func applyLineColors(to storage: NSTextStorage) {
        let fullText = storage.string as NSString
        applyLineColors(to: storage,
                        in: NSRange(location: 0, length: fullText.length))
    }

    /// Walks the storage line-by-line within the line-aligned expansion
    /// of `range` and stamps each line with a colour by prefix:
    /// `#` → accent, `//` → muted, else default text.
    ///
    /// Attribute-only edits (which is all this method makes) don't
    /// trigger `.editedCharacters`, so re-stamping from inside the
    /// storage delegate doesn't recurse.
    func applyLineColors(to storage: NSTextStorage, in range: NSRange) {
        let fullText = storage.string as NSString
        let total = fullText.length
        guard total > 0 else { return }
        // Clamp to valid bounds — `editedRange` post-edit can in
        // principle land at `total` for an insert-at-end.
        let safeLoc = min(max(0, range.location), total)
        let safeLen = min(max(0, range.length), total - safeLoc)
        let scope = fullText.lineRange(for: NSRange(location: safeLoc, length: safeLen))

        let defaultColor = NSColor(VektorTheme.text)
        let headerColor  = NSColor(VektorTheme.accent)
        let commentColor = NSColor(VektorTheme.muted)
        var loc = scope.location
        let end = scope.location + scope.length
        while loc < end {
            let lineRange = fullText.lineRange(for: NSRange(location: loc, length: 0))
            let lineString = fullText.substring(with: lineRange)
            let trimmed = lineString.trimmingCharacters(in: .whitespacesAndNewlines)
            let colour: NSColor
            if trimmed.hasPrefix("#") {
                colour = headerColor
            } else if trimmed.hasPrefix("//") {
                colour = commentColor
            } else {
                colour = defaultColor
            }
            storage.addAttribute(.foregroundColor, value: colour, range: lineRange)
            // Dim any trailing `// comment` on expression / header lines
            // so it matches the muted styling of full-line `//` comments.
            // The engine already strips trailing comments before eval
            // (see NumiEngine.evaluate) — the styling just lagged behind.
            // Skipped on pure-comment lines, where the whole line is
            // already muted via the base pass above.
            if !trimmed.hasPrefix("//") {
                applyTrailingCommentStyling(to: storage,
                                            lineString: lineString,
                                            lineRange: lineRange,
                                            commentColor: commentColor)
            }
            // Layer `@reference` styling on top of the base line
            // colour so jump links pop with an underline + accent
            // tint regardless of whether the line was a header,
            // comment, or expression.
            applyPageReferenceStyling(to: storage,
                                      lineString: lineString,
                                      lineRange: lineRange)
            let newLoc = lineRange.location + lineRange.length
            if newLoc == loc { break }
            loc = newLoc
        }
    }

    /// Matches a trailing `// …` comment on an expression line. The
    /// leading `\s+` requirement is what protects URLs like `http://…`
    /// from being mis-styled as comments — same rule the engine uses
    /// for stripping before evaluation. Group 1 captures the comment
    /// itself (starting at the `//`), excluding the whitespace
    /// separator and excluding the line's trailing newline.
    private static let trailingCommentRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"\s+(//[^\r\n]*)"#)
    }()

    private func applyTrailingCommentStyling(to storage: NSTextStorage,
                                             lineString: String,
                                             lineRange: NSRange,
                                             commentColor: NSColor) {
        guard let regex = Self.trailingCommentRegex else { return }
        let ns = lineString as NSString
        guard let match = regex.firstMatch(in: lineString,
                                           range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges >= 2 else { return }
        let local = match.range(at: 1)
        let absRange = NSRange(location: lineRange.location + local.location,
                               length: local.length)
        storage.addAttribute(.foregroundColor, value: commentColor, range: absRange)
    }

    /// Attribute key the AutocompletingTextView's mouseDown handler
    /// reads to decide whether a click targets an `@ref` jump.
    /// Value is the slug string (lowercased first word after `@`).
    static let pageReferenceAttributeKey =
        NSAttributedString.Key("vektor.calculator.pageRef")

    /// Highlight every `@\w+` token inside `lineString` and stash the
    /// slug on a custom attribute so click handling can read it back
    /// without re-scanning the text. Resolved refs (slug points to a
    /// real doc) get accent + solid underline — the "active link"
    /// treatment. Unresolved refs get muted + dotted underline so the
    /// user can still tell `@math` is an @-token, but at a glance sees
    /// it won't navigate anywhere yet.
    private static let pageRefRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"@[A-Za-z0-9_-]+"#)
    }()
    private func applyPageReferenceStyling(to storage: NSTextStorage,
                                           lineString: String,
                                           lineRange: NSRange) {
        guard let regex = Self.pageRefRegex else { return }
        let ns = lineString as NSString
        let resolvedColor = NSColor(VektorTheme.accent)
        let unresolvedColor = NSColor(VektorTheme.muted)
        let resolvedUnderline = NSUnderlineStyle.single.rawValue
        let unresolvedUnderline = NSUnderlineStyle([.single, .patternDot]).rawValue
        regex.enumerateMatches(in: lineString,
                               range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let m = match else { return }
            // Absolute range = line offset + match's offset within the line.
            let absRange = NSRange(location: lineRange.location + m.range.location,
                                   length: m.range.length)
            let slug = String(ns.substring(with: m.range).lowercased().dropFirst())
            let resolves = resolvePageReference(slug)
            storage.addAttribute(.foregroundColor,
                                 value: resolves ? resolvedColor : unresolvedColor,
                                 range: absRange)
            storage.addAttribute(.underlineStyle,
                                 value: resolves ? resolvedUnderline : unresolvedUnderline,
                                 range: absRange)
            // Always stash the slug so the click handler can still read
            // it — navigation is gated separately on the resolver, so an
            // unresolved click falls through to default caret placement
            // without us having to scrub the attribute.
            storage.addAttribute(Self.pageReferenceAttributeKey,
                                 value: slug,
                                 range: absRange)
        }
    }
}

// MARK: - ColumnContainer (the unified documentView)

/// The single documentView inside the outer NSScrollView. Lays out the
/// editor, divider, and gutter horizontally. Height = editor's content
/// height (the gutter wraps to whatever rows fit; per-line paragraph
/// spacing keeps the columns aligned row-for-row).
final class ColumnContainer: NSView {
    weak var editor: AutocompletingTextView?
    weak var divider: DividerStrip?
    weak var gutter: GutterView?

    /// Width of the left (editor) column. Updated via drag on the
    /// divider; written back to the SwiftUI binding via the callback.
    var editorWidth: CGFloat = 420
    var onEditorWidthChange: (CGFloat) -> Void = { _ in }

    /// No-op kept on the interface so `UnifiedEditor.updateNSView` can
    /// still call it after `tv.string` is reassigned. Previously this
    /// invalidated a `lastAppliedExtras` skip cache; that cache caused
    /// stale paragraph spacing for multi-airport briefings whose result
    /// text grew across multiple async data arrivals, so the skip was
    /// removed and the stamping is now unconditional.
    func invalidateAppliedExtras() {
        // Intentional no-op (kept for call-site compatibility).
    }

    private let minEditorWidth: CGFloat = 240
    private let minGutterWidth: CGFloat = 160
    private let dividerHitWidth: CGFloat = 11   // wider hit area for easier drag

    /// Re-entrancy guard: `relayoutAndResize` sets `frame`, which can schedule
    /// another `layout()` pass — without this the two would recurse.
    private var isRelayingOut = false
    /// Container width at the last *full* relayout. Starts at -1 so the first
    /// real layout — and any width change, including a tab re-appear that
    /// first lays out at zero width — re-runs the full pass, recomputing the
    /// gutter's paragraph-spacing extras AND line y-positions *together*.
    /// Without this, a relayout that ran at zero width left the spacing
    /// unapplied and the gutter drew multi-line results on top of each other.
    private var lastFullLayoutWidth: CGFloat = -1

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        relayoutChildren()
        // A plain layout pass only repositions the columns. When the width
        // settles (notably 0 → real on a tab re-appear, or a window resize),
        // the gutter's extras + y-positions are stale — run the full pass.
        if !isRelayingOut, bounds.width >= 1,
           abs(bounds.width - lastFullLayoutWidth) > 0.5 {
            relayoutAndResize()
        }
    }

    /// Bottom padding so the user can scroll the cursor away from
    /// the window edge — like "scroll past end" in code editors.
    private let scrollPastEndPadding: CGFloat = 80

    /// Resize self to match the editor's content height, then re-lay
    /// out the three subviews. Called on text-did-change, results
    /// change, and width change.
    ///
    /// Order matters:
    ///   1. Apply gutter's per-line extra heights → editor paragraph
    ///      spacing. This pushes editor source lines down to make
    ///      room for multi-line METAR/TAF results below the result's
    ///      starting y. Without it, a tall result draws on top of
    ///      the next source line in the gutter.
    ///   2. Editor relays out with the new spacing.
    ///   3. Compute new line y-positions from the editor and hand
    ///      them to the gutter so it draws each result at the
    ///      correct y (now accounting for the spacing).
    ///   4. Size documentView to whichever is taller — editor content
    ///      height or the gutter's max-row-bottom — plus scroll-past-
    ///      end padding so the cursor never sits at the window edge.
    func relayoutAndResize() {
        guard !isRelayingOut, let editor, let gutter else { return }
        isRelayingOut = true
        defer { isRelayingOut = false }
        lastFullLayoutWidth = bounds.width
        // Step 0: lay out so the gutter knows its width (needed for
        // bounding-rect calculations).
        relayoutChildren()

        // Step 1: gutter computes per-source-line extra heights and
        // the container stamps them as paragraph spacing on the editor.
        let extras = gutter.computeExtraHeights()
        applyEditorParagraphSpacing(extras: extras, in: editor)

        // Step 2: layout the editor with the new spacing.
        editor.layoutManager?.ensureLayout(for: editor.textContainer!)
        let used = editor.layoutManager?.usedRect(for: editor.textContainer!).height ?? 0
        let editorContentHeight = used + editor.textContainerInset.height * 2

        // Step 3: per-line y-positions for the gutter to draw against.
        gutter.lineYPositions = computeLineYPositions(for: editor)
        gutter.needsDisplay = true

        // Step 4: size documentView. Take whichever bottom edge is
        // lower (editor or gutter), pad for scroll-past-end, clamp
        // to at least the scroll view's visible height so a short
        // document still fills the window.
        let gutterBottom = gutter.maxRowBottom()
        let scrollHeight = enclosingScrollView?.contentView.bounds.height ?? 0
        let target = max(editorContentHeight,
                         gutterBottom,
                         scrollHeight) + scrollPastEndPadding
        if abs(frame.height - target) > 0.5 {
            var f = frame
            f.size.height = target
            frame = f
            relayoutChildren()
        }
    }

    /// Walk the editor's text storage paragraph-by-paragraph and stamp
    /// each line with a `paragraphSpacing` equal to the gutter's
    /// extra-height entry for that source line. Attribute changes
    /// (no character changes) don't re-trigger textDidChange, so no
    /// recursion risk.
    private func applyEditorParagraphSpacing(extras: [Int: CGFloat], in tv: NSTextView) {
        // Unconditional re-stamp. A previous version skipped this walk
        // when the extras dict matched the last applied one — that
        // saved keystroke work but missed the multi-airport-briefing
        // case where the result text grows asynchronously across
        // several data arrivals. Re-stamping each call is cheap
        // (couple of dict accesses + an attribute set per line), and
        // the gutter / boundingRect cache layered above handles the
        // expensive part.
        guard let storage = tv.textStorage else { return }
        let fullText = storage.string as NSString
        let total = fullText.length
        storage.beginEditing()
        var loc = 0
        var lineIdx = 0
        while loc <= total {
            let lineRange = fullText.lineRange(for: NSRange(location: loc, length: 0))
            let extra = extras[lineIdx] ?? 0
            let p = NSMutableParagraphStyle()
            p.minimumLineHeight = 18
            p.maximumLineHeight = 18
            p.paragraphSpacing = extra
            storage.addAttribute(.paragraphStyle, value: p, range: lineRange)
            lineIdx += 1
            let newLoc = lineRange.location + lineRange.length
            if newLoc == loc { break }
            loc = newLoc
        }
        storage.endEditing()
    }

    /// Walks the text storage paragraph-by-paragraph and asks the
    /// layoutManager for the y position of each line's first glyph
    /// (in textContainer-local coordinates, plus the inset). The
    /// gutter draws each result at the position keyed by source line.
    private func computeLineYPositions(for tv: NSTextView) -> [Int: CGFloat] {
        guard let lm = tv.layoutManager,
              let container = tv.textContainer,
              let storage = tv.textStorage
        else { return [:] }
        let text = storage.string as NSString
        let total = text.length
        var map: [Int: CGFloat] = [:]
        var lineIdx = 0
        var loc = 0
        let inset = tv.textContainerInset.height
        while loc <= total {
            let lineRange = text.lineRange(for: NSRange(location: loc, length: 0))
            let glyphRange = lm.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            let y: CGFloat
            if glyphRange.length > 0 {
                let rect = lm.boundingRect(forGlyphRange: glyphRange, in: container)
                y = rect.minY + inset
            } else {
                // Empty trailing line — use the extra line fragment rect.
                y = lm.extraLineFragmentRect.minY + inset
            }
            map[lineIdx] = y
            lineIdx += 1
            let newLoc = lineRange.location + lineRange.length
            if newLoc == loc { break }
            loc = newLoc
        }
        return map
    }

    private func relayoutChildren() {
        guard let editor, let divider, let gutter else { return }
        let total = bounds.width
        if total < 1 { return }

        let maxEditor = max(minEditorWidth, total - minGutterWidth - 1)
        let clamped = min(max(editorWidth, minEditorWidth), maxEditor)
        if abs(clamped - editorWidth) > 0.5 {
            editorWidth = clamped
        }
        let leftWidth = editorWidth
        let rightWidth = max(0, total - leftWidth - 1)

        editor.frame = NSRect(x: 0, y: 0, width: leftWidth, height: bounds.height)
        editor.textContainer?.containerSize = NSSize(
            width: leftWidth,
            height: .greatestFiniteMagnitude
        )

        divider.frame = NSRect(
            x: leftWidth + 0.5 - dividerHitWidth / 2,
            y: 0,
            width: dividerHitWidth,
            height: bounds.height
        )

        gutter.frame = NSRect(
            x: leftWidth + 1,
            y: 0,
            width: rightWidth,
            height: bounds.height
        )
        gutter.needsDisplay = true
    }

    /// Click-anywhere-to-edit. The NSTextView is `isVerticallyResizable`
    /// so on an empty document its frame shrinks to the height of a
    /// single insertion-point row — clicks below that frame fall onto
    /// the bare ColumnContainer and do nothing. Forwarding them here
    /// activates the editor and moves the caret to the end of the text,
    /// matching the expected feel ("the editable surface is the whole
    /// pane").
    override func mouseDown(with event: NSEvent) {
        guard let editor else {
            super.mouseDown(with: event)
            return
        }
        // Only intercept clicks inside the editor's *column* (left of
        // the divider), not the gutter — the gutter has its own click
        // handlers for axis details, send-to-calculator, etc.
        let p = convert(event.locationInWindow, from: nil)
        let inEditorColumn = p.x < editorWidth
        let outsideEditorFrame = !editor.frame.contains(p)
        if inEditorColumn && outsideEditorFrame {
            window?.makeFirstResponder(editor)
            let endLoc = (editor.string as NSString).length
            editor.setSelectedRange(NSRange(location: endLoc, length: 0))
            // Scroll caret into view so the user sees it land at the end.
            editor.scrollRangeToVisible(NSRange(location: endLoc, length: 0))
            return
        }
        super.mouseDown(with: event)
    }

    /// Live drag — fully synchronous per pixel. We deliberately do
    /// NOT call `onEditorWidthChange` here: writing to the SwiftUI
    /// @AppStorage binding triggers a full updateNSView round-trip
    /// that re-runs all the layout work asynchronously, producing
    /// the visible asymmetry where the editor (synchronous reflow)
    /// races ahead of the gutter (async catch-up). Doing the full
    /// relayoutAndResize here keeps both columns in lockstep at the
    /// cost of one synchronous pass per drag pixel — still cheap
    /// enough for typical docs.
    func dragDivider(by delta: CGFloat) {
        let total = bounds.width
        let maxEditor = max(minEditorWidth, total - minGutterWidth - 1)
        let proposed = editorWidth + delta
        let clamped = min(max(proposed, minEditorWidth), maxEditor)
        if abs(clamped - editorWidth) > 0.5 {
            editorWidth = clamped
            relayoutAndResize()
        }
    }

    /// End-of-drag commit: flush the chosen width back to SwiftUI's
    /// @AppStorage so the user's preferred split persists. Called
    /// once per drag (on mouseUp), not per pixel.
    func commitDragEnd() {
        onEditorWidthChange(editorWidth)
    }
}

// MARK: - DividerStrip

/// A 1pt visible line with an 11pt invisible hit area. Hover changes
/// the cursor to .resizeLeftRight; click-drag emits horizontal deltas
/// to the container. The visible line is `VektorTheme.muted` so it
/// reads as a real separator without being loud — brighter on hover.
final class DividerStrip: NSView {
    /// Fired during drag with each horizontal delta.
    var onDrag: (CGFloat) -> Void = { _ in }
    /// Fired once on mouseUp so the container can flush the final
    /// width back to persistent storage (avoids a per-pixel SwiftUI
    /// binding write that would otherwise make the drag jank).
    var onDragEnd: () -> Void = { }
    private var trackingArea: NSTrackingArea?
    private var lastDragPoint: NSPoint?
    private var isHovering: Bool = false {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // 1pt vertical hairline centred in the hit zone. A bit brighter
        // than VektorTheme.divider so the user can find the drag handle.
        let line = NSRect(
            x: (bounds.width - 1) / 2,
            y: 0,
            width: 1,
            height: bounds.height
        )
        // Light grey at rest, slightly brighter grey on hover — never
        // a colour-tint, so the divider reads as chrome, not an
        // active element.
        let colour = isHovering
            ? NSColor(VektorTheme.muted)
            : NSColor(VektorTheme.muted).withAlphaComponent(0.45)
        colour.setFill()
        line.fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInActiveApp, .mouseEnteredAndExited, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        NSCursor.resizeLeftRight.set()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        lastDragPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let last = lastDragPoint else { return }
        let now = convert(event.locationInWindow, from: nil)
        let delta = now.x - last.x
        if abs(delta) > 0.5 {
            onDrag(delta)
            // Track from the new position so further drag is incremental.
            lastDragPoint = NSPoint(x: last.x + delta, y: now.y)
        }
    }

    override func mouseUp(with event: NSEvent) {
        lastDragPoint = nil
        onDragEnd()
    }
}

// MARK: - GutterView

/// Draws per-line result rows at y-positions sourced from the editor's
/// layoutManager, so each result sits exactly next to its source line
/// even when lines wrap, when comments use blank rows, or when the
/// document has gaps.
///
/// The container computes the editor's per-line y-positions after each
/// layout pass and hands them in via `lineYPositions`. Drawing then
/// just looks up the position for each `LineResult.line` and renders
/// the value (and any annotation) at that y.
///
/// Rendering is pure AppKit (NSAttributedString.draw) for performance
/// and full control over right-alignment + wrapping.
final class GutterView: NSView {
    var results: [LineResult] = [] {
        didSet {
            if oldValue == results { return }
            // Drop cache entries for lines no longer present so the
            // dict can't grow unboundedly across edits. Per-line entries
            // for lines whose content is unchanged stay valid via the
            // cacheKey check inside `cachedEntry`.
            let validLines = Set(results.map { $0.line })
            resultCache = resultCache.filter { validLines.contains($0.key) }
            needsDisplay = true
            refreshToolTips()
        }
    }
    /// Source-line index → y position (in this view's coordinate
    /// space, equal to editor's because both share ColumnContainer
    /// with frame.origin.y = 0). Updated by ColumnContainer after
    /// every editor layout pass.
    var lineYPositions: [Int: CGFloat] = [:] {
        didSet {
            needsDisplay = true
            refreshToolTips()
        }
    }
    var renderValue: (LineResult) -> NSAttributedString = { _ in NSAttributedString() }
    var renderAnnotation: (LineResult) -> NSAttributedString? = { _ in nil }

    override var isFlipped: Bool { true }

    let rowHeight: CGFloat = 18
    let horizontalPadding: CGFloat = 18

    /// Per-line cached render output: the materialised NSAttributedString
    /// plus its measured bounding rect for the current text width. Both
    /// `computeExtraHeights`, `maxRowBottom`, `draw`, and
    /// `accessibilityChildren` consult this — without the cache they each
    /// re-render and re-measure the same result on every keystroke.
    private struct ResultCacheEntry {
        let cacheKey: String
        let value: NSAttributedString
        let valueRect: CGRect
        let annotation: NSAttributedString?
        let annotationRect: CGRect
    }
    private var resultCache: [Int: ResultCacheEntry] = [:]
    private var resultCacheTextWidth: CGFloat = -1

    /// Content key — when this changes for a given line, the cached
    /// entry is stale and gets recomputed. Tone is folded in because
    /// it picks the colour for the freshness annotation. The hint is
    /// folded in because it can change while the value stays identical —
    /// typing a `thb` line *below* a bare `150` retro-attaches "EUR?" to
    /// the 150's line, whose value text hasn't moved.
    private static func cacheKey(for r: LineResult) -> String {
        let value = r.value ?? ""
        let annLabel = r.annotation?.label ?? ""
        let annTone: String
        switch r.annotation?.tone {
        case .fresh?:    annTone = "f"
        case .stale?:    annTone = "s"
        case .outdated?: annTone = "o"
        case nil:        annTone = "-"
        }
        return "\(r.kind.rawValue)|\(value)|\(annLabel)|\(annTone)|\(r.hint ?? "")"
    }

    private func cachedEntry(for r: LineResult, textWidth: CGFloat) -> ResultCacheEntry {
        if resultCacheTextWidth != textWidth {
            resultCache.removeAll(keepingCapacity: true)
            resultCacheTextWidth = textWidth
        }
        let key = Self.cacheKey(for: r)
        if let entry = resultCache[r.line], entry.cacheKey == key {
            return entry
        }
        let value = renderValue(r)
        let valueRect = value.boundingRect(
            with: NSSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let annotation = renderAnnotation(r)
        let annotationRect: CGRect
        if let ann = annotation {
            annotationRect = ann.boundingRect(
                with: NSSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
        } else {
            annotationRect = .zero
        }
        let entry = ResultCacheEntry(
            cacheKey: key,
            value: value,
            valueRect: valueRect,
            annotation: annotation,
            annotationRect: annotationRect
        )
        resultCache[r.line] = entry
        return entry
    }

    // MARK: - Per-row tool tips
    //
    // Hovering a gutter row shows the source-line text that produced the
    // result. Useful when reverse-engineering an unfamiliar doc and the
    // result wraps multiple lines (METAR briefings especially) — the
    // tooltip tells you which input line is behind the output.

    /// Rebuild the per-row tooltip rects from current results + y-positions.
    /// Called from the setters of both — keeps tooltips in sync with the
    /// drawn layout without us having to invalidate them by hand.
    private func refreshToolTips() {
        removeAllToolTips()
        let textWidth = max(0, bounds.width - horizontalPadding * 2)
        guard textWidth > 0 else { return }
        for r in results {
            guard let y = lineYPositions[r.line] else { continue }
            let entry = cachedEntry(for: r, textWidth: textWidth)
            let height = max(rowHeight, entry.valueRect.height) + entry.annotationRect.height
            let rect = NSRect(x: 0, y: y, width: bounds.width, height: height)
            addToolTip(rect, owner: self, userData: nil)
        }
    }

    /// macOS tooltip callback. The system invokes this with the cursor's
    /// in-view point; we hit-test against our row geometry and return the
    /// source line as the tooltip text. Empty string means "no tooltip
    /// here," which is what the system uses to suppress display. Marked
    /// `@objc` because `addToolTip(_:owner:userData:)` looks the method
    /// up dynamically via the ObjC runtime rather than a Swift protocol.
    @objc func view(_ view: NSView,
                    stringForToolTip tag: NSView.ToolTipTag,
                    point: NSPoint,
                    userData data: UnsafeMutableRawPointer?) -> String {
        let textWidth = max(0, bounds.width - horizontalPadding * 2)
        guard textWidth > 0 else { return "" }
        for r in results {
            guard let y = lineYPositions[r.line] else { continue }
            let entry = cachedEntry(for: r, textWidth: textWidth)
            let height = max(rowHeight, entry.valueRect.height) + entry.annotationRect.height
            if point.y >= y && point.y < y + height {
                let trimmed = r.raw.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return "" }
                // Prefix the line number so a long doc is easier to
                // cross-reference; the source line itself is the meat.
                return "Line \(r.line + 1): \(trimmed)"
            }
        }
        return ""
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - bounds.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged { refreshToolTips() }
    }

    /// Per source line: how much vertical space the result needs *beyond*
    /// the editor's standard line height. Used by the container to push
    /// editor lines down via paragraph spacing so a multi-line METAR
    /// doesn't draw on top of the next source line.
    func computeExtraHeights() -> [Int: CGFloat] {
        let textWidth = max(0, bounds.width - horizontalPadding * 2)
        guard textWidth > 0 else { return [:] }
        var extras: [Int: CGFloat] = [:]
        for r in results {
            let entry = cachedEntry(for: r, textWidth: textWidth)
            let total = max(rowHeight, entry.valueRect.height) + entry.annotationRect.height
            let extra = total - rowHeight
            if extra > 0.5 { extras[r.line] = extra }
        }
        return extras
    }

    /// Maximum y reached by any drawn row, in this view's coordinate
    /// space. Used by the container so the documentView's height
    /// includes any gutter overflow past the editor's content height.
    func maxRowBottom() -> CGFloat {
        let textWidth = max(0, bounds.width - horizontalPadding * 2)
        guard textWidth > 0 else { return 0 }
        var maxY: CGFloat = 0
        for r in results {
            guard let y = lineYPositions[r.line] else { continue }
            let entry = cachedEntry(for: r, textWidth: textWidth)
            let rowBottom = y + max(rowHeight, entry.valueRect.height) + entry.annotationRect.height
            if rowBottom > maxY { maxY = rowBottom }
        }
        return maxY
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(VektorTheme.background).setFill()
        bounds.fill()

        let textWidth = max(0, bounds.width - horizontalPadding * 2)
        guard textWidth > 0 else { return }

        for r in results {
            guard let y = lineYPositions[r.line] else { continue }
            let entry = cachedEntry(for: r, textWidth: textWidth)

            let valueDrawRect = NSRect(
                x: horizontalPadding,
                y: y,
                width: textWidth,
                height: max(rowHeight, entry.valueRect.height)
            )
            entry.value.draw(with: valueDrawRect,
                             options: [.usesLineFragmentOrigin, .usesFontLeading])

            if let annotation = entry.annotation {
                let annDrawRect = NSRect(
                    x: horizontalPadding,
                    y: y + max(rowHeight, entry.valueRect.height),
                    width: textWidth,
                    height: entry.annotationRect.height
                )
                annotation.draw(with: annDrawRect,
                                options: [.usesLineFragmentOrigin, .usesFontLeading])
            }
        }
    }

    // MARK: - Accessibility
    //
    // Results are drawn directly into the view via `NSAttributedString.draw`,
    // so VoiceOver has no per-row hooks unless we synthesise them. We expose
    // the gutter as a `.group` and advertise one `NSAccessibilityElement` per
    // result row, positioned at the same y the renderer drew it. Each row's
    // value is `"<computed value>. <annotation>"` so a screen-reader user
    // hears both the result and any freshness / age label.

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .group }

    override func accessibilityLabel() -> String? { "Calculator results" }

    override func accessibilityChildren() -> [Any]? {
        let textWidth = max(0, bounds.width - horizontalPadding * 2)
        guard textWidth > 0 else { return [] }
        var elements: [NSAccessibilityElement] = []
        elements.reserveCapacity(results.count)
        for r in results {
            guard let y = lineYPositions[r.line] else { continue }
            let entry = cachedEntry(for: r, textWidth: textWidth)
            let valueText = entry.value.string.trimmingCharacters(in: .whitespacesAndNewlines)
            let annotationText = entry.annotation?.string.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // Skip empty rows so VO doesn't read "blank" between content.
            if valueText.isEmpty && annotationText.isEmpty { continue }

            let height = max(rowHeight, entry.valueRect.height) + entry.annotationRect.height

            let element = NSAccessibilityElement()
            element.setAccessibilityRole(.staticText)
            element.setAccessibilityParent(self)
            element.setAccessibilityFrameInParentSpace(
                NSRect(x: horizontalPadding, y: y, width: textWidth, height: height)
            )
            element.setAccessibilityLabel("Result for line \(r.line + 1)")
            let combined: String = {
                if !valueText.isEmpty && !annotationText.isEmpty {
                    return "\(valueText). \(annotationText)"
                }
                return valueText.isEmpty ? annotationText : valueText
            }()
            element.setAccessibilityValue(combined)
            elements.append(element)
        }
        return elements
    }
}
