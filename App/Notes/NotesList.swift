import SwiftUI

/// Middle column: list of notes matching the current filter + search.
/// One row per note — title, two-line preview, relative modified date,
/// and a row of tag chips. Selection drives the editor in the right
/// column.
struct NotesList: View {
    @ObservedObject var store: NotesStore
    let filter: NotesFilter
    let search: String
    @Binding var selectedID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(TallyTheme.divider)
            if filteredNotes.isEmpty {
                emptyState
            } else {
                List(selection: $selectedID) {
                    ForEach(filteredNotes) { note in
                        NotesListRow(note: note)
                            .tag(note.id)
                            .contextMenu { rowContextMenu(for: note) }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(TallyTheme.background)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text(filter.displayName)
                .font(.headline)
                .foregroundStyle(TallyTheme.text)
            Spacer()
            Text("\(filteredNotes.count)")
                .font(.caption)
                .foregroundStyle(TallyTheme.muted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: filter.iconName)
                .font(.system(size: 22))
                .foregroundStyle(TallyTheme.muted)
            Text(emptyText)
                .font(.callout)
                .foregroundStyle(TallyTheme.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private var emptyText: String {
        if !search.isEmpty { return "No notes match \"\(search)\"." }
        switch filter {
        case .all:       return "No notes yet — press ⌘N to create one."
        case .archived:  return "Archive is empty."
        case .trashed:   return "Trash is empty."
        case .untagged:  return "No untagged notes."
        case .tag(let p): return "No notes tagged #\(p)."
        }
    }

    // MARK: - Context menu

    @ViewBuilder
    private func rowContextMenu(for note: Note) -> some View {
        if note.isTrashed {
            Button("Restore") { restore(note) }
            Button("Delete permanently", role: .destructive) {
                store.remove(note.id)
            }
        } else {
            Button(note.isArchived ? "Unarchive" : "Archive") {
                toggleArchive(note)
            }
            Button("Move to Trash", role: .destructive) {
                trash(note)
            }
        }
    }

    private func toggleArchive(_ note: Note) {
        var copy = note
        copy.isArchived.toggle()
        copy.modifiedAt = Date()
        store.add(copy)
    }

    private func trash(_ note: Note) {
        var copy = note
        copy.isTrashed = true
        copy.isArchived = false
        copy.modifiedAt = Date()
        store.add(copy)
        if selectedID == note.id { selectedID = nil }
    }

    private func restore(_ note: Note) {
        var copy = note
        copy.isTrashed = false
        copy.modifiedAt = Date()
        store.add(copy)
    }

    // MARK: - Filtering

    private var filteredNotes: [Note] {
        let base: [Note]
        switch filter {
        case .trashed:
            base = store.trashedNotes
        case .archived:
            base = store.archivedNotes
        case .all:
            base = store.activeNotes.filter { !$0.isArchived }
        case .untagged:
            base = store.activeNotes.filter { !$0.isArchived && $0.tags.isEmpty }
        case .tag(let path):
            base = store.activeNotes.filter { note in
                guard !note.isArchived else { return false }
                return note.tags.contains { tag in
                    tag == path || tag.hasPrefix("\(path)/")
                }
            }
        }
        guard !search.trimmingCharacters(in: .whitespaces).isEmpty else { return base }
        let q = search.lowercased()
        return base.filter { note in
            note.body.lowercased().contains(q)
        }
    }
}

private struct NotesListRow: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(note.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TallyTheme.text)
                    .lineLimit(1)
                Spacer()
                Text(NotesListRow.dateFormatter.localizedString(
                    for: note.modifiedAt, relativeTo: Date()))
                    .font(.system(size: 10))
                    .foregroundStyle(TallyTheme.muted)
            }
            if !note.preview.isEmpty {
                Text(note.preview)
                    .font(.system(size: 11))
                    .foregroundStyle(TallyTheme.muted)
                    .lineLimit(2)
            }
            if !note.tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(note.tags.prefix(4), id: \.self) { tag in
                        Text("#\(tag)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(TallyTheme.accent)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(TallyTheme.accent.opacity(0.10))
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private static let dateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}
