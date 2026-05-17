import SwiftUI

/// Top-level Notes pane. Three columns separated by `HSplitView`
/// dividers the user can drag: tag sidebar, notes list, editor +
/// preview. State (selection, filter, search, view-mode) lives here
/// and flows down; persisted note data lives in the injected
/// `NotesStore`.
struct NotesPane: View {
    @ObservedObject var store: NotesStore

    @State private var filter: NotesFilter = .all
    @State private var search: String = ""
    @State private var selectedID: UUID?

    var body: some View {
        HSplitView {
            NotesSidebar(store: store,
                         filter: $filter,
                         search: $search)
                .frame(minWidth: 180, idealWidth: 220, maxWidth: 320)

            NotesList(store: store,
                      filter: filter,
                      search: search,
                      selectedID: $selectedID)
                .frame(minWidth: 220, idealWidth: 280, maxWidth: 400)

            editorColumn
                .frame(minWidth: 360)
        }
        .background(TallyTheme.background)
        // The new-note button lives in the chrome (see ContentView)
        // instead of `.toolbar` here — the custom chrome and a SwiftUI
        // window-toolbar fight for the title-bar zone and the chrome
        // (which carries the pane picker) was losing, leaving the user
        // unable to navigate back out of the Notes pane.
        .onChange(of: store.saved.count) { old, new in
            // When a note is added via the chrome button, jump to it.
            if new > old,
               let newest = store.saved.max(by: { $0.modifiedAt < $1.modifiedAt }) {
                selectedID = newest.id
            }
        }
        .onAppear {
            // First-launch convenience: select the most recently
            // modified note so the editor isn't empty.
            if selectedID == nil {
                selectedID = store.activeNotes.first?.id
            }
            // Walk the assets dir and remove files that no longer have
            // any note referencing them. Cheap (file enumeration is
            // O(asset_count)) so worth doing on every appearance.
            NotesAssets.purgeOrphans(referencedBy: store.saved)
        }
        .onChange(of: filter) { _, _ in
            // Selection should be reset whenever the filter swaps to a
            // bucket that doesn't contain the previously-selected note.
            if let sel = selectedID,
               !visibleIDs.contains(sel) {
                selectedID = visibleIDs.first
            }
        }
    }

    // MARK: - Editor column

    @ViewBuilder
    private var editorColumn: some View {
        if let id = selectedID,
           store.saved.contains(where: { $0.id == id }) {
            NotesEditor(store: store,
                        noteID: id,
                        titleIndex: titleIndex,
                        onOpenNote: { selectedID = $0 })
        } else {
            VStack(spacing: 8) {
                Image(systemName: "note.text")
                    .font(.system(size: 32))
                    .foregroundStyle(TallyTheme.muted)
                Text("Select a note, or press ⌘N to create one.")
                    .font(.callout)
                    .foregroundStyle(TallyTheme.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(TallyTheme.background)
        }
    }

    // MARK: - Helpers

    /// IDs visible in the middle column for the current filter+search.
    /// Used to keep the selection sensible across filter changes.
    private var visibleIDs: [UUID] {
        // Mirror the filter logic from NotesList for selection bookkeeping.
        let base: [Note]
        switch filter {
        case .trashed:   base = store.trashedNotes
        case .archived:  base = store.archivedNotes
        case .all:       base = store.activeNotes.filter { !$0.isArchived }
        case .untagged:  base = store.activeNotes.filter { !$0.isArchived && $0.tags.isEmpty }
        case .tag(let p):
            base = store.activeNotes.filter { note in
                !note.isArchived && note.tags.contains { $0 == p || $0.hasPrefix("\(p)/") }
            }
        }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = q.isEmpty ? base : base.filter { $0.body.lowercased().contains(q) }
        return filtered.map(\.id)
    }

    /// Case-insensitive title → id lookup used by the preview to
    /// resolve `[[wiki link]]` tokens. Built from all non-trashed notes
    /// so wiki links can target archived notes too.
    private var titleIndex: [String: UUID] {
        var index: [String: UUID] = [:]
        for note in store.saved where !note.isTrashed {
            index[note.title.lowercased()] = note.id
        }
        return index
    }

}
