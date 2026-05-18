import AppKit

/// `NSTextAttachment` subclasses for the four "atomic" notes-pane
/// elements that render as a single visual unit but originate from
/// multi-character markdown: checkbox, bullet marker, inline image,
/// markdown table.
///
/// Each subclass:
///   1. Carries a `sourceMarkdown` string so the renderer can
///      reconstruct the original `.md` body from the attributed
///      storage at save time.
///   2. Owns its own drawing through `image(forBounds:textContainer:characterIndex:)`
///      — much more robust than the previous overlay-on-top-of-hidden-
///      text approach: the caret naturally treats each as a single
///      character, selection highlights cover the cell, copy gives
///      the source markdown, and find-bar hits land at the
///      attachment's character index.

/// Marker protocol so the renderer can ask any attachment "what
/// markdown did you come from?" without a giant switch on concrete
/// type. All subclasses below conform.
protocol MarkdownSerialisable {
    /// Bytes that should appear in the saved `.md` body in place of
    /// the U+FFFC character the attachment occupies in storage.
    var sourceMarkdown: String { get }
}

// MARK: - Checkbox

final class CheckboxAttachment: NSTextAttachment, MarkdownSerialisable {
    /// Mutable so toggling via mouseDown only requires updating the
    /// existing attachment, not re-rendering the document. Bounded
    /// `setNeedsDisplay` on the layout manager redraws the single cell.
    var checked: Bool

    /// Visible size of the checkbox glyph. Sized to the editor font
    /// at construction; the layout manager treats the value as the
    /// natural width of the attachment cell.
    let glyphSize: CGFloat

    init(checked: Bool, glyphSize: CGFloat) {
        self.checked = checked
        self.glyphSize = glyphSize
        super.init(data: nil, ofType: nil)
    }
    required init?(coder: NSCoder) {
        self.checked = false
        self.glyphSize = 14
        super.init(coder: coder)
    }

    var sourceMarkdown: String { checked ? "[x]" : "[ ]" }

    override func attachmentBounds(for textContainer: NSTextContainer?,
                                   proposedLineFragment lineFrag: CGRect,
                                   glyphPosition position: CGPoint,
                                   characterIndex charIndex: Int) -> CGRect {
        // Origin: place the glyph slightly above the baseline so it
        // visually centres on the row's cap-height rather than its
        // descender.
        let y: CGFloat = -3
        return CGRect(x: 0, y: y, width: glyphSize + 4, height: glyphSize)
    }

    override func image(forBounds imageBounds: CGRect,
                        textContainer: NSTextContainer?,
                        characterIndex charIndex: Int) -> NSImage? {
        let name = checked ? "checkmark.square.fill" : "square"
        let cfg = NSImage.SymbolConfiguration(pointSize: glyphSize, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) else { return nil }
        let tint: NSColor = checked
            ? NSColor.systemOrange
            : NSColor.secondaryLabelColor
        symbol.isTemplate = true
        let size = glyphSize
        return NSImage(size: NSSize(width: size + 4, height: size), flipped: false) { rect in
            tint.set()
            rect.fill()
            symbol.draw(in: NSRect(x: 2, y: 0, width: size, height: size),
                        from: .zero,
                        operation: .destinationIn,
                        fraction: 1.0)
            return true
        }
    }
}

// MARK: - Bullet

final class BulletAttachment: NSTextAttachment, MarkdownSerialisable {
    let glyphSize: CGFloat
    /// The exact source bytes — `-`, `*`, or `+` — preserved so a
    /// round-trip through render → serialise produces identical
    /// markdown (don't normalise dialects).
    let marker: String

    init(marker: String, glyphSize: CGFloat) {
        self.marker = marker
        self.glyphSize = glyphSize
        super.init(data: nil, ofType: nil)
    }
    required init?(coder: NSCoder) {
        self.marker = "-"
        self.glyphSize = 14
        super.init(coder: coder)
    }

    var sourceMarkdown: String { "\(marker) " }

    override func attachmentBounds(for textContainer: NSTextContainer?,
                                   proposedLineFragment lineFrag: CGRect,
                                   glyphPosition position: CGPoint,
                                   characterIndex charIndex: Int) -> CGRect {
        CGRect(x: 0, y: -3, width: glyphSize + 6, height: glyphSize)
    }

    override func image(forBounds imageBounds: CGRect,
                        textContainer: NSTextContainer?,
                        characterIndex charIndex: Int) -> NSImage? {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: glyphSize + 2, weight: .bold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let glyph = NSAttributedString(string: "•", attributes: attrs)
        let size = glyph.size()
        return NSImage(size: NSSize(width: glyphSize + 6, height: glyphSize), flipped: false) { rect in
            let drawAt = NSPoint(
                x: (rect.width - size.width) / 2,
                y: (rect.height - size.height) / 2 - 1
            )
            glyph.draw(at: drawAt)
            return true
        }
    }
}

// MARK: - Inline image

final class InlineImageAttachment: NSTextAttachment, MarkdownSerialisable {
    let assetURLString: String
    let altText: String
    private let renderedImage: NSImage?

    init(assetURLString: String, altText: String, maxWidth: CGFloat) {
        self.assetURLString = assetURLString
        self.altText = altText
        if let url = URL(string: assetURLString),
           let fileURL = NotesAssets.resolve(url),
           let raw = NSImage(contentsOf: fileURL) {
            // Cap to maxWidth, preserve aspect ratio. Render once at
            // construction so repeated re-draws don't re-decode.
            let originalSize = raw.size
            let scale = min(1.0, maxWidth / max(originalSize.width, 1))
            let display = NSSize(width: originalSize.width * scale,
                                 height: originalSize.height * scale)
            let resized = NSImage(size: display)
            resized.lockFocus()
            raw.draw(in: NSRect(origin: .zero, size: display),
                     from: NSRect(origin: .zero, size: originalSize),
                     operation: .sourceOver, fraction: 1.0)
            resized.unlockFocus()
            self.renderedImage = resized
        } else {
            self.renderedImage = nil
        }
        super.init(data: nil, ofType: nil)
    }
    required init?(coder: NSCoder) {
        self.assetURLString = ""
        self.altText = ""
        self.renderedImage = nil
        super.init(coder: coder)
    }

    var sourceMarkdown: String { "![\(altText)](\(assetURLString))" }

    override func attachmentBounds(for textContainer: NSTextContainer?,
                                   proposedLineFragment lineFrag: CGRect,
                                   glyphPosition position: CGPoint,
                                   characterIndex charIndex: Int) -> CGRect {
        let size = renderedImage?.size ?? NSSize(width: 80, height: 16)
        // y=0 sits the image on the baseline. Inline images render
        // best slightly raised so the line containing the image
        // doesn't push surrounding text downward by the full image
        // height (text wraps around naturally above the image, but
        // the offset keeps the cap-height roughly aligned).
        return CGRect(x: 0, y: 0, width: size.width, height: size.height)
    }

    override func image(forBounds imageBounds: CGRect,
                        textContainer: NSTextContainer?,
                        characterIndex charIndex: Int) -> NSImage? {
        return renderedImage
    }
}

// MARK: - Table

/// Parsed table data. Re-used by the renderer and TableAttachment.
struct NotesTableData: Equatable {
    var headers: [String]
    var rows: [[String]]
    /// The raw source markdown — kept verbatim so a no-edit round-trip
    /// preserves the user's original cell padding, alignment hints,
    /// and trailing pipes exactly.
    var sourceMarkdown: String
}

final class TableAttachment: NSTextAttachment, MarkdownSerialisable {
    let data: NotesTableData
    let baseFontSize: CGFloat
    private let renderedImage: NSImage?
    private let renderedSize: NSSize

    init(data: NotesTableData, baseFontSize: CGFloat, maxWidth: CGFloat) {
        self.data = data
        self.baseFontSize = baseFontSize
        let (image, size) = Self.renderImage(table: data,
                                             baseFontSize: baseFontSize,
                                             maxWidth: maxWidth)
        self.renderedImage = image
        self.renderedSize = size
        super.init(data: nil, ofType: nil)
    }
    required init?(coder: NSCoder) {
        self.data = NotesTableData(headers: [], rows: [], sourceMarkdown: "")
        self.baseFontSize = 14
        self.renderedImage = nil
        self.renderedSize = .zero
        super.init(coder: coder)
    }

    var sourceMarkdown: String { data.sourceMarkdown }

    override func attachmentBounds(for textContainer: NSTextContainer?,
                                   proposedLineFragment lineFrag: CGRect,
                                   glyphPosition position: CGPoint,
                                   characterIndex charIndex: Int) -> CGRect {
        CGRect(x: 0, y: 0, width: renderedSize.width, height: renderedSize.height)
    }

    override func image(forBounds imageBounds: CGRect,
                        textContainer: NSTextContainer?,
                        characterIndex charIndex: Int) -> NSImage? {
        return renderedImage
    }

    /// Pre-render the table to an NSImage. Sized to fit the longest
    /// cell per column with each row a fixed height. Header band gets
    /// a 10% accent tint; cells share 1pt borders in the system
    /// separator colour.
    private static func renderImage(table: NotesTableData,
                                    baseFontSize: CGFloat,
                                    maxWidth: CGFloat) -> (NSImage?, NSSize) {
        guard !table.headers.isEmpty else { return (nil, .zero) }
        let colCount = table.headers.count
        let cellPadH: CGFloat = 8
        let rowHeight = baseFontSize * 1.8
        let totalRows = 1 + table.rows.count
        let cellAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: baseFontSize - 1)
        ]

        // Per-column widest content width (header or data) + padding.
        var widths: [CGFloat] = Array(repeating: 0, count: colCount)
        for c in 0..<colCount {
            let header = table.headers[safe: c] ?? ""
            var widest = (header as NSString).size(withAttributes: cellAttrs).width
            for row in table.rows {
                let cell = row[safe: c] ?? ""
                let w = (cell as NSString).size(withAttributes: cellAttrs).width
                if w > widest { widest = w }
            }
            widths[c] = widest + cellPadH * 2
        }
        let total = widths.reduce(0, +)
        if total > maxWidth {
            let scale = maxWidth / total
            widths = widths.map { $0 * scale }
        }
        let tableWidth = widths.reduce(0, +)
        let tableHeight = CGFloat(totalRows) * rowHeight

        let image = NSImage(size: NSSize(width: tableWidth, height: tableHeight),
                            flipped: true) { rect in
            // Background tint on header row.
            NSColor.systemOrange.withAlphaComponent(0.10).setFill()
            NSRect(x: 0, y: 0, width: tableWidth, height: rowHeight).fill()

            // Cell text per row.
            for rowIdx in 0..<totalRows {
                let cells: [String] = rowIdx == 0
                    ? table.headers
                    : (table.rows[safe: rowIdx - 1] ?? [])
                let isHeader = rowIdx == 0
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: isHeader
                        ? NSFont.systemFont(ofSize: baseFontSize - 1, weight: .semibold)
                        : NSFont.systemFont(ofSize: baseFontSize - 1),
                    .foregroundColor: NSColor.labelColor,
                ]
                var x: CGFloat = 0
                let y = CGFloat(rowIdx) * rowHeight
                for col in 0..<colCount {
                    let cellW = widths[col]
                    let text = cells[safe: col] ?? ""
                    let attr = NSAttributedString(string: text, attributes: attrs)
                    let size = attr.size()
                    attr.draw(at: NSPoint(
                        x: x + cellPadH,
                        y: y + (rowHeight - size.height) / 2 - 1
                    ))
                    x += cellW
                }
            }
            // Grid: outer rect + row dividers + column dividers.
            NSColor.separatorColor.setStroke()
            let path = NSBezierPath()
            path.lineWidth = 1.0
            path.appendRect(NSRect(x: 0, y: 0, width: tableWidth, height: tableHeight))
            for r in 1..<totalRows {
                let y = CGFloat(r) * rowHeight
                path.move(to: NSPoint(x: 0, y: y))
                path.line(to: NSPoint(x: tableWidth, y: y))
            }
            var x: CGFloat = 0
            for c in 0..<(colCount - 1) {
                x += widths[c]
                path.move(to: NSPoint(x: x, y: 0))
                path.line(to: NSPoint(x: x, y: tableHeight))
            }
            path.stroke()
            return true
        }
        return (image, NSSize(width: tableWidth, height: tableHeight))
    }
}

// MARK: - Helpers

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
