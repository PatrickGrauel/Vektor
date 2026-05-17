import Foundation
import SwiftUI

/// Persistent collection of notes, backed by the generic
/// `PersistentStore<T>` that other panes already use for their saved
/// scenarios. Notes dedupe by id (the store's default behaviour) so
/// editing a note in place preserves its UUID across saves.
typealias NotesStore = PersistentStore<Note>

extension PersistentStore where T == Note {
    static func notes() -> NotesStore {
        NotesStore(
            storageKey: "tally.notes.v1",
            matches: { $0.id == $1.id },
            merge: { existing, new in
                // Always preserve the original creation date — the new
                // value may have been built from an editor commit that
                // copied a fresh `createdAt`. We also bump `modifiedAt`
                // to "now" on every merge so the list-by-most-recently-
                // edited sort is correct without callers having to set
                // it themselves.
                var copy = new
                copy.createdAt = existing.createdAt
                copy.modifiedAt = Date()
                return copy
            }
        )
    }

    /// Convenience: notes filtered for the active list (not trashed),
    /// sorted by most recently modified.
    var activeNotes: [Note] {
        saved
            .filter { !$0.isTrashed }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// Notes that are in the trash. Used by the "Trash" sidebar bucket.
    var trashedNotes: [Note] {
        saved
            .filter { $0.isTrashed }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// Notes in the archive bucket (still live, just hidden from the
    /// default "All Notes" list to keep the working set tight).
    var archivedNotes: [Note] {
        saved
            .filter { $0.isArchived && !$0.isTrashed }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }
}
