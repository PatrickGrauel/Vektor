import SwiftUI
import AppKit

/// NSTextView-backed plain-text editor with two markdown-aware extras:
///
///   1. **Inline syntax highlighting.** Hashtags, wiki-links, headings,
///      bold, emphasis, and inline code are coloured live as the user
///      types. There's no preview-style structural collapse — every
///      character the user typed is still on screen, just tinted. This
///      matches Bear / iA Writer / Obsidian's edit-mode behaviour and
///      avoids the round-trip-rendering trap.
///   2. **Image paste.** Pasting an image from the clipboard writes the
///      bytes to the assets directory and inserts a markdown image
///      reference using the `notes-asset://` scheme. The preview
///      resolves the scheme back to a file URL.
///
/// All other editing — selection, find, autocomplete, undo — comes
/// from the stock NSTextView for free.
struct MarkdownTextEditor: NSViewRepresentable {
    @Binding var text: String

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
        textView.textContainerInset = NSSize(width: 20, height: 16)
        textView.font = .systemFont(ofSize: 14)
        textView.backgroundColor = NSColor(TallyTheme.background)
        textView.drawsBackground = true
        textView.textColor = NSColor(TallyTheme.text)
        textView.insertionPointColor = NSColor(TallyTheme.accent)

        textView.string = text
        context.coordinator.applyHighlighting(to: textView)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NotesEditorTextView else { return }
        // Only reset the buffer when the externally-bound text genuinely
        // diverges from what's on screen — otherwise we'd clobber the
        // caret position on every keystroke as the binding round-trips.
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

        /// Apply markdown syntax highlighting. Runs over the full text
        /// because the affected ranges (heading spans, multi-line code
        /// blocks) are not always local to the insertion point. For
        /// reasonable note sizes (<50 KB) this is comfortably fast.
        func applyHighlighting(to tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            let full = NSRange(location: 0, length: (tv.string as NSString).length)
            storage.beginEditing()
            // Reset to base attributes — same font/color used in
            // makeNSView so a no-token region reads as normal text.
            let base: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14),
                .foregroundColor: NSColor(TallyTheme.text),
            ]
            storage.setAttributes(base, range: full)

            for (range, kind) in NoteTokenizer.highlightRanges(in: tv.string) {
                guard range.location >= 0,
                      range.location + range.length <= full.length else { continue }
                let attrs = attributes(for: kind)
                storage.addAttributes(attrs, range: range)
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
                return [
                    .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                ]
            case .emphasis:
                return [
                    .font: NSFontManager.shared.font(
                        withFamily: NSFont.systemFont(ofSize: 14).familyName ?? "",
                        traits: .italicFontMask,
                        weight: 5,
                        size: 14
                    ) ?? NSFont.systemFont(ofSize: 14),
                ]
            case .code:
                return [
                    .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                    .foregroundColor: NSColor(TallyTheme.accent),
                ]
            case .heading:
                return [
                    .font: NSFont.boldSystemFont(ofSize: 16),
                    .foregroundColor: NSColor(TallyTheme.text),
                ]
            }
        }

        /// Pasteboard hook — fires from `NotesEditorTextView.paste(_:)`.
        /// Returns true if we consumed the paste with an image insert;
        /// false to let NSTextView handle it as plain text.
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
                // Move the caret to the end of the inserted snippet so
                // the user can keep typing.
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
/// so we can intercept image pastes before NSText's default handling
/// (which would otherwise drop binary image data on the floor).
final class NotesEditorTextView: NSTextView {
    weak var coordinator: MarkdownTextEditor.Coordinator?

    override func paste(_ sender: Any?) {
        if let coordinator, coordinator.handlePaste(in: self) {
            return
        }
        super.paste(sender)
    }
}
