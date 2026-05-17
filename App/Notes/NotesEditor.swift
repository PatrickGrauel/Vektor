import SwiftUI

/// Right-most column when a note is selected: editor on the left,
/// markdown preview on the right (or one of them solo, depending on the
/// view-mode toggle). Body edits debounce-save into the store so the
/// list-row preview and tag tree update as you type.
struct NotesEditor: View {
    @ObservedObject var store: NotesStore
    let noteID: UUID
    /// Map of `lowercase title → note id`, used by the preview's
    /// `[[wiki link]]` resolver.
    let titleIndex: [String: UUID]
    /// Called when the preview opens a wiki link to another note.
    let onOpenNote: (UUID) -> Void

    @State private var draftBody: String = ""
    /// Track the note id the draft was loaded from so we don't write
    /// it back to the wrong note when the selection changes.
    @State private var draftSourceID: UUID?
    @State private var saveWorkItem: DispatchWorkItem?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().background(TallyTheme.divider)
            content
        }
        .background(TallyTheme.background)
        .onAppear { loadDraft() }
        .onChange(of: noteID) { _, _ in loadDraft() }
        .onChange(of: draftBody) { _, _ in scheduleSave() }
    }

    // MARK: - Toolbar

    /// Right-aligned ellipsis menu with note-level actions. The
    /// previous editor/split/preview segmented control was removed —
    /// the split layout below is the default and the segmented picker
    /// wasn't pulling its weight.
    private var toolbar: some View {
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
            HSplitView {
                MarkdownTextEditor(text: $draftBody)
                    .frame(minWidth: 240)
                NotesPreview(text: draftBody,
                             titleIndex: titleIndex,
                             onOpenWikiLink: onOpenNote)
                    .frame(minWidth: 240)
            }
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
        // Flush any pending save into the old note before we swap.
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
        // 350 ms debounce — long enough that typing doesn't burn writes
        // to UserDefaults on every keystroke, short enough that the
        // sidebar tag tree and list preview update before the eye
        // expects them to.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func flushPendingSave() {
        if let work = saveWorkItem {
            work.cancel()
            saveWorkItem = nil
            // Force a synchronous final write if there's a divergence
            // between draft and store.
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
        // Skip the write if the body didn't actually change — guards
        // against re-entrant draftBody updates triggering writes.
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
