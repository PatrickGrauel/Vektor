import SwiftUI
import AppKit
import TallyEngine

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

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(TallyTheme.background)
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
        tv.isRichText = false
        tv.isEditable = true
        tv.isSelectable = true
        tv.allowsUndo = true
        tv.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        tv.textColor = NSColor(TallyTheme.text)
        tv.insertionPointColor = NSColor(TallyTheme.accent)
        tv.backgroundColor = NSColor(TallyTheme.background)
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
            .foregroundColor: NSColor(TallyTheme.text),
            .paragraphStyle: paragraph,
        ]
        tv.string = text
        tv.textStorage?.delegate = context.coordinator
        if let storage = tv.textStorage {
            UnifiedCoordinator.applyLineColors(to: storage)
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

        // Text refresh (e.g. document switch).
        if tv.string != text {
            tv.string = text
            if let storage = tv.textStorage {
                UnifiedCoordinator.applyLineColors(to: storage)
            }
        }

        // Pipe latest renderers + data into the gutter.
        column.gutter?.results = results
        column.gutter?.renderValue = renderValue
        column.gutter?.renderAnnotation = renderAnnotation

        // Width may have changed from the call site.
        column.editorWidth = editorWidth

        column.needsLayout = true
        column.relayoutAndResize()
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

    init(text: Binding<String>) {
        self.text = text
    }

    func textDidChange(_ notification: Notification) {
        guard let tv = notification.object as? AutocompletingTextView else { return }
        text.wrappedValue = tv.string
        tv.recomputeSuggestion()
        column?.relayoutAndResize()
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
        Self.applyLineColors(to: textStorage, in: editedRange)
    }

    /// Full-document colour pass. Used for the initial render and for
    /// bulk text replacements (document switch) where the storage
    /// delegate path doesn't fire on a per-line basis.
    static func applyLineColors(to storage: NSTextStorage) {
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
    static func applyLineColors(to storage: NSTextStorage, in range: NSRange) {
        let fullText = storage.string as NSString
        let total = fullText.length
        guard total > 0 else { return }
        // Clamp to valid bounds — `editedRange` post-edit can in
        // principle land at `total` for an insert-at-end.
        let safeLoc = min(max(0, range.location), total)
        let safeLen = min(max(0, range.length), total - safeLoc)
        let scope = fullText.lineRange(for: NSRange(location: safeLoc, length: safeLen))

        let defaultColor = NSColor(TallyTheme.text)
        let headerColor  = NSColor(TallyTheme.accent)
        let commentColor = NSColor(TallyTheme.muted)
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
            let newLoc = lineRange.location + lineRange.length
            if newLoc == loc { break }
            loc = newLoc
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

    private let minEditorWidth: CGFloat = 240
    private let minGutterWidth: CGFloat = 160
    private let dividerHitWidth: CGFloat = 11   // wider hit area for easier drag

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        relayoutChildren()
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
        guard let editor, let gutter else { return }
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
/// to the container. The visible line is `TallyTheme.muted` so it
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
        // than TallyTheme.divider so the user can find the drag handle.
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
            ? NSColor(TallyTheme.muted)
            : NSColor(TallyTheme.muted).withAlphaComponent(0.45)
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
        didSet { needsDisplay = true }
    }
    /// Source-line index → y position (in this view's coordinate
    /// space, equal to editor's because both share ColumnContainer
    /// with frame.origin.y = 0). Updated by ColumnContainer after
    /// every editor layout pass.
    var lineYPositions: [Int: CGFloat] = [:] {
        didSet { needsDisplay = true }
    }
    var renderValue: (LineResult) -> NSAttributedString = { _ in NSAttributedString() }
    var renderAnnotation: (LineResult) -> NSAttributedString? = { _ in nil }

    override var isFlipped: Bool { true }

    let rowHeight: CGFloat = 18
    let horizontalPadding: CGFloat = 18

    /// Per source line: how much vertical space the result needs *beyond*
    /// the editor's standard line height. Used by the container to push
    /// editor lines down via paragraph spacing so a multi-line METAR
    /// doesn't draw on top of the next source line.
    func computeExtraHeights() -> [Int: CGFloat] {
        let textWidth = max(0, bounds.width - horizontalPadding * 2)
        guard textWidth > 0 else { return [:] }
        var extras: [Int: CGFloat] = [:]
        for r in results {
            let value = renderValue(r)
            let valueRect = value.boundingRect(
                with: NSSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            let annHeight: CGFloat = {
                guard let ann = renderAnnotation(r) else { return 0 }
                return ann.boundingRect(
                    with: NSSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading]
                ).height
            }()
            let total = max(rowHeight, valueRect.height) + annHeight
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
            let value = renderValue(r)
            let valueRect = value.boundingRect(
                with: NSSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            let annHeight: CGFloat = {
                guard let ann = renderAnnotation(r) else { return 0 }
                return ann.boundingRect(
                    with: NSSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading]
                ).height
            }()
            let rowBottom = y + max(rowHeight, valueRect.height) + annHeight
            if rowBottom > maxY { maxY = rowBottom }
        }
        return maxY
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(TallyTheme.background).setFill()
        bounds.fill()

        let textWidth = max(0, bounds.width - horizontalPadding * 2)
        guard textWidth > 0 else { return }

        for r in results {
            guard let y = lineYPositions[r.line] else { continue }
            let value = renderValue(r)
            let annotation = renderAnnotation(r)

            let valueRect = value.boundingRect(
                with: NSSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            let valueDrawRect = NSRect(
                x: horizontalPadding,
                y: y,
                width: textWidth,
                height: max(rowHeight, valueRect.height)
            )
            value.draw(with: valueDrawRect,
                       options: [.usesLineFragmentOrigin, .usesFontLeading])

            if let annotation {
                let annRect = annotation.boundingRect(
                    with: NSSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading]
                )
                let annDrawRect = NSRect(
                    x: horizontalPadding,
                    y: y + max(rowHeight, valueRect.height),
                    width: textWidth,
                    height: annRect.height
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
            let value = renderValue(r)
            let annotation = renderAnnotation(r)
            let valueText = value.string.trimmingCharacters(in: .whitespacesAndNewlines)
            let annotationText = annotation?.string.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // Skip empty rows so VO doesn't read "blank" between content.
            if valueText.isEmpty && annotationText.isEmpty { continue }

            let valueRect = value.boundingRect(
                with: NSSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            let annHeight: CGFloat = annotation.map {
                $0.boundingRect(
                    with: NSSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading]
                ).height
            } ?? 0
            let height = max(rowHeight, valueRect.height) + annHeight

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
