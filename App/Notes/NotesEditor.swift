import SwiftUI
import AppKit

/// Right-most column when a note is selected. Single integrated editor
/// surface (no separate preview pane — formatting renders inline as the
/// user types). A floating formatting bar at the bottom exposes the
/// common actions Bear users expect: headings, lists, bold/italic,
/// links, images, tables. Body edits debounce-save into the store so
/// the list-row preview and sidebar tag tree stay current.
struct NotesEditor: View {
    @ObservedObject var store: NotesStore
    let noteID: UUID

    @State private var draftBody: String = ""
    @State private var draftSourceID: UUID?
    @State private var saveWorkItem: DispatchWorkItem?
    @StateObject private var controller = NotesEditorController()

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider().background(TallyTheme.divider)
            content
            if note != nil {
                Divider().background(TallyTheme.divider)
                FormattingBar(controller: controller)
            }
        }
        .background(TallyTheme.background)
        .onAppear { loadDraft() }
        .onChange(of: noteID) { _, _ in loadDraft() }
        .onChange(of: draftBody) { _, _ in scheduleSave() }
    }

    // MARK: - Top header

    private var headerBar: some View {
        HStack(spacing: 6) {
            Spacer()
            Menu {
                if let note = note {
                    if note.isTrashed {
                        Button("Restore from Trash") { restore(note) }
                        Button("Delete permanently", role: .destructive) {
                            store.remove(note.id)
                        }
                    } else {
                        Button(note.isArchived ? "Move out of Archive" : "Archive") {
                            toggleArchive(note)
                        }
                        Button("Move to Trash", role: .destructive) {
                            trash(note)
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if note == nil {
            placeholder
        } else {
            MarkdownTextEditor(text: $draftBody, controller: controller)
        }
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "note.text")
                .font(.system(size: 32))
                .foregroundStyle(TallyTheme.muted)
            Text("Select a note, or press ⌘N to create one.")
                .font(.callout)
                .foregroundStyle(TallyTheme.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Draft <-> store

    private var note: Note? { store.saved.first { $0.id == noteID } }

    private func loadDraft() {
        flushPendingSave()
        if let n = note {
            draftBody = n.body
            draftSourceID = n.id
        } else {
            draftBody = ""
            draftSourceID = nil
        }
    }

    private func scheduleSave() {
        guard let sourceID = draftSourceID else { return }
        saveWorkItem?.cancel()
        let body = draftBody
        let work = DispatchWorkItem {
            commit(sourceID: sourceID, body: body)
        }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func flushPendingSave() {
        if let work = saveWorkItem {
            work.cancel()
            saveWorkItem = nil
            if let sourceID = draftSourceID,
               let stored = store.saved.first(where: { $0.id == sourceID }),
               stored.body != draftBody {
                commit(sourceID: sourceID, body: draftBody)
            }
        }
    }

    @MainActor
    private func commit(sourceID: UUID, body: String) {
        guard let existing = store.saved.first(where: { $0.id == sourceID }) else { return }
        guard existing.body != body else { return }
        var copy = existing
        copy.body = body
        copy.modifiedAt = Date()
        store.add(copy)
    }

    // MARK: - Lifecycle actions

    private func toggleArchive(_ note: Note) {
        flushPendingSave()
        var copy = note
        copy.isArchived.toggle()
        copy.modifiedAt = Date()
        store.add(copy)
    }
    private func trash(_ note: Note) {
        flushPendingSave()
        var copy = note
        copy.isTrashed = true
        copy.isArchived = false
        copy.modifiedAt = Date()
        store.add(copy)
    }
    private func restore(_ note: Note) {
        flushPendingSave()
        var copy = note
        copy.isTrashed = false
        copy.modifiedAt = Date()
        store.add(copy)
    }
}

// MARK: - Editor controller

/// Glue object that lets the SwiftUI formatting bar drive the underlying
/// NSTextView. The MarkdownTextEditor stores a weak reference here when
/// the NSTextView is created, and the bar's buttons call the high-level
/// `insert*` / `wrap*` methods to splice markdown syntax at the caret.
@MainActor
final class NotesEditorController: ObservableObject {
    weak var textView: NSTextView?

    /// Wrap the current selection with `prefix` and `suffix`. If the
    /// selection already starts with `prefix` and ends with `suffix`,
    /// the wrap is removed (toggle behaviour). Empty selections insert
    /// the markers and place the caret between them.
    func wrapSelection(prefix: String, suffix: String) {
        guard let tv = textView else { return }
        let ns = tv.string as NSString
        let range = tv.selectedRange()
        let selected = ns.substring(with: range)
        let pfxLen = (prefix as NSString).length
        let sfxLen = (suffix as NSString).length

        if selected.hasPrefix(prefix) && selected.hasSuffix(suffix),
           selected.count >= pfxLen + sfxLen {
            // Toggle off: strip the wrapping markers.
            let inner = (selected as NSString)
                .substring(with: NSRange(location: pfxLen,
                                         length: (selected as NSString).length - pfxLen - sfxLen))
            replace(range: range, with: inner,
                    newSelection: NSRange(location: range.location,
                                          length: (inner as NSString).length))
            return
        }

        let wrapped = "\(prefix)\(selected)\(suffix)"
        replace(range: range, with: wrapped,
                newSelection: selected.isEmpty
                    ? NSRange(location: range.location + pfxLen, length: 0)
                    : NSRange(location: range.location, length: (wrapped as NSString).length))
    }

    /// Toggle a line-prefix on every line in the selection (or on the
    /// caret line if there's no selection). Used for headings, lists,
    /// quotes, and checkboxes — Bear-style.
    func toggleLinePrefix(_ prefix: String) {
        guard let tv = textView else { return }
        let ns = tv.string as NSString
        let selRange = tv.selectedRange()
        let lineRange = ns.lineRange(for: selRange)
        let lineText = ns.substring(with: lineRange)
        let trimmedLeading = lineText.drop { $0 == " " || $0 == "\t" }
        let indentLen = lineText.count - trimmedLeading.count
        let body = String(trimmedLeading)

        let new: String
        if body.hasPrefix(prefix) {
            // Toggle off.
            let stripped = String(body.dropFirst(prefix.count))
            new = String(repeating: " ", count: indentLen) + stripped
        } else {
            // If a different heading marker is present, strip it first
            // so re-applying H1 over H2 swaps cleanly.
            var stripped = body
            for marker in ["###### ", "##### ", "#### ", "### ", "## ", "# ", "- [ ] ", "- [x] ", "- ", "> "] {
                if stripped.hasPrefix(marker) {
                    stripped = String(stripped.dropFirst(marker.count))
                    break
                }
            }
            new = String(repeating: " ", count: indentLen) + prefix + stripped
        }
        replace(range: lineRange, with: new,
                newSelection: NSRange(location: lineRange.location + (new as NSString).length,
                                      length: 0))
    }

    /// Insert text at the caret, optionally placing the caret some
    /// distance back from the end (used for `[ ](url)` link templates
    /// where we want the caret inside the URL).
    func insertText(_ text: String, caretOffsetFromEnd: Int = 0) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        let length = (text as NSString).length
        replace(range: range, with: text,
                newSelection: NSRange(location: range.location + length - caretOffsetFromEnd,
                                      length: 0))
    }

    /// Open NSOpenPanel for an image, copy it into the assets directory,
    /// and insert the markdown reference at the caret.
    func pickAndInsertImage() {
        guard let tv = textView else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .gif, .heic]
        guard panel.runModal() == .OK, let url = panel.url,
              let image = NSImage(contentsOf: url) else { return }
        do {
            let assetURL = try NotesAssets.saveImage(image)
            let snippet = "![](\(assetURL.absoluteString))"
            let range = tv.selectedRange()
            replace(range: range, with: snippet,
                    newSelection: NSRange(location: range.location + (snippet as NSString).length,
                                          length: 0))
        } catch {
            NSSound.beep()
        }
    }

    /// Insert a simple 2-row × 2-col table template. Cursor is placed
    /// in the first header cell so the user can start typing immediately.
    func insertTable() {
        let template = """
        | Column 1 | Column 2 |
        | -------- | -------- |
        |          |          |

        """
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        replace(range: range, with: template,
                newSelection: NSRange(location: range.location + 2, length: 8))
    }

    // MARK: - Internals

    private func replace(range: NSRange, with text: String, newSelection: NSRange) {
        guard let tv = textView else { return }
        // shouldChangeText / didChangeText is the documented way to mutate
        // text from outside the user's typing flow while keeping undo
        // history coherent.
        if tv.shouldChangeText(in: range, replacementString: text) {
            tv.replaceCharacters(in: range, with: text)
            tv.didChangeText()
            tv.selectedRange = newSelection
        }
    }
}

// MARK: - Bottom formatting bar

/// Bear-style strip of formatting actions pinned to the bottom of the
/// editor. Each button is a thin wrapper around a controller method so
/// the editor stays the source of truth for text mutation + undo.
private struct FormattingBar: View {
    @ObservedObject var controller: NotesEditorController

    var body: some View {
        HStack(spacing: 2) {
            // Heading dropdown — H1/H2/H3 toggle the line's `#` prefix.
            Menu {
                Button("Heading 1") { controller.toggleLinePrefix("# ") }
                Button("Heading 2") { controller.toggleLinePrefix("## ") }
                Button("Heading 3") { controller.toggleLinePrefix("### ") }
                Divider()
                Button("Body") {
                    // Strip any heading by toggling an empty heading off.
                    controller.toggleLinePrefix("")
                }
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "textformat.size")
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8))
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Heading style")
            .frame(height: 22)
            .padding(.horizontal, 4)

            barButton("checkmark.square", help: "Checkbox (- [ ])") {
                controller.toggleLinePrefix("- [ ] ")
            }
            barButton("list.bullet", help: "Bulleted list") {
                controller.toggleLinePrefix("- ")
            }
            barButton("text.quote", help: "Block quote") {
                controller.toggleLinePrefix("> ")
            }

            divider

            barButton("bold", help: "Bold (⌘B)") {
                controller.wrapSelection(prefix: "**", suffix: "**")
            }
            barButton("italic", help: "Italic (⌘I)") {
                controller.wrapSelection(prefix: "_", suffix: "_")
            }
            barButton("chevron.left.forwardslash.chevron.right", help: "Inline code") {
                controller.wrapSelection(prefix: "`", suffix: "`")
            }

            divider

            barButton("link", help: "Link") {
                // 4-char tail = "(url)" minus the leading `(` so the
                // caret lands right where the URL goes.
                controller.insertText("[](url)", caretOffsetFromEnd: 4)
            }
            barButton("tablecells", help: "Insert table") {
                controller.insertTable()
            }
            barButton("photo", help: "Insert image") {
                controller.pickAndInsertImage()
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(TallyTheme.surface)
    }

    private func barButton(_ system: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 13))
                .foregroundStyle(TallyTheme.text)
                .frame(width: 28, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var divider: some View {
        Rectangle()
            .fill(TallyTheme.divider)
            .frame(width: 1, height: 16)
            .padding(.horizontal, 4)
    }
}
