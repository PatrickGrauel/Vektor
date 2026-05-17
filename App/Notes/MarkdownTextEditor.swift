import SwiftUI
import AppKit

/// NSTextView-backed markdown editor that renders inline as you type:
///
///   - Headings render at their final size (H1 22pt, H2 18pt, H3 16pt).
///   - Bold / italic / inline code render with the right typography.
///   - Markdown syntax characters (`**`, `_`, `#`, `` ` ``) are dimmed
///     so they recede next to the rendered text, Bear-style.
///   - Hashtags and `[[wiki links]]` are accent-coloured.
///   - Image references (`![](notes-asset://...)`) collapse into the
///     actual image inline via NSTextAttachment — no separate preview
///     pane needed.
///   - Image paste from the clipboard writes to the assets directory and
///     inserts the corresponding markdown reference.
///
/// External callers (the formatting bar) drive insertions through the
/// `NotesEditorController`, which holds a weak reference to the
/// NSTextView.
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
        init(_ parent: MarkdownTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            applyHighlighting(to: tv)
        }

        /// Apply inline styling. Runs over the full text on every
        /// change — acceptable for typical note sizes. The
        /// NSTextAttachment substitution for images is what makes the
        /// editor look like Bear without needing a separate preview.
        func applyHighlighting(to tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            let full = NSRange(location: 0, length: (tv.string as NSString).length)
            storage.beginEditing()
            // Reset to base attributes — re-applied on every run so we
            // don't accumulate stale styles from removed tokens.
            let base: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14),
                .foregroundColor: NSColor(TallyTheme.text),
            ]
            storage.setAttributes(base, range: full)

            for (range, kind) in NoteTokenizer.highlightRanges(in: tv.string) {
                guard range.location >= 0,
                      range.location + range.length <= full.length else { continue }
                storage.addAttributes(attributes(for: kind), range: range)
                applySyntaxDimming(kind: kind, range: range, storage: storage, source: tv.string)
            }

            // Inline images — replace `![](notes-asset://...)` ranges
            // with an NSTextAttachment showing the file. Done after
            // syntax so positioning math still sees the original text.
            for imageRange in inlineImageRanges(in: tv.string) {
                applyImageAttachment(storage: storage, range: imageRange, source: tv.string)
            }
            storage.endEditing()
        }

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
                // Default heading attributes — the size is bumped by
                // applySyntaxDimming based on marker count (H1>H2>H3).
                return [
                    .font: NSFont.boldSystemFont(ofSize: 14),
                    .foregroundColor: NSColor(TallyTheme.text),
                ]
            }
        }

        /// Dim the markdown syntax characters inside a token so they
        /// recede next to the rendered text. For headings, also bump
        /// the inner font size based on the `#` count.
        private func applySyntaxDimming(kind: NoteTokenizer.TokenKind,
                                        range: NSRange,
                                        storage: NSTextStorage,
                                        source: String) {
            let dim = NSColor(TallyTheme.muted).withAlphaComponent(0.55)
            switch kind {
            case .bold:
                guard range.length > 4 else { return }
                storage.addAttribute(.foregroundColor, value: dim,
                                     range: NSRange(location: range.location, length: 2))
                storage.addAttribute(.foregroundColor, value: dim,
                                     range: NSRange(location: range.location + range.length - 2, length: 2))
            case .emphasis, .code:
                guard range.length > 2 else { return }
                storage.addAttribute(.foregroundColor, value: dim,
                                     range: NSRange(location: range.location, length: 1))
                storage.addAttribute(.foregroundColor, value: dim,
                                     range: NSRange(location: range.location + range.length - 1, length: 1))
            case .wikiLink:
                guard range.length > 4 else { return }
                storage.addAttribute(.foregroundColor, value: dim,
                                     range: NSRange(location: range.location, length: 2))
                storage.addAttribute(.foregroundColor, value: dim,
                                     range: NSRange(location: range.location + range.length - 2, length: 2))
            case .heading:
                // Count leading `#` characters within the heading line.
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
                storage.addAttribute(.foregroundColor, value: dim,
                                     range: NSRange(location: range.location, length: markerLen))
            default:
                break
            }
        }

        // MARK: Inline images

        private func inlineImageRanges(in source: String) -> [NSRange] {
            let pattern = #"!\[[^\]]*\]\(notes-asset://[^)]+\)"#
            let ns = source as NSString
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            return regex.matches(in: source, range: NSRange(location: 0, length: ns.length))
                .map { $0.range }
        }

        /// Substitute the markdown image span with an NSTextAttachment
        /// rendering the actual asset. We don't mutate the underlying
        /// string — only the attribute layer — so the source markdown
        /// is preserved and the user can still edit it (the chars sit
        /// behind the attachment cell, selectable).
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
            // Hide the underlying markdown text under the image.
            storage.addAttribute(.foregroundColor, value: NSColor.clear, range: range)
        }

        // MARK: Paste

        /// Pasteboard hook — fires from `NotesEditorTextView.paste(_:)`.
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
    }
}

/// NSTextView subclass that routes `paste(_:)` through the coordinator
/// so we can intercept image pastes before NSText's default handling.
final class NotesEditorTextView: NSTextView {
    weak var coordinator: MarkdownTextEditor.Coordinator?

    override func paste(_ sender: Any?) {
        if let coordinator, coordinator.handlePaste(in: self) {
            return
        }
        super.paste(sender)
    }
}
