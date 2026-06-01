import SwiftUI

/// Drops down from the SHEET title in the calculator chrome — the single
/// entry point for sheet switching, pinning, and deletion. Pinned sheets
/// appear in their own section at the top with their keyboard shortcuts
/// (⌘⇧1/2/3) next to them; everything else falls below the divider
/// sorted by most-recently-updated.
///
/// Replaces the older split-design (separate "pinned dropdown" + "all
/// docs hamburger" popovers) — one place to manage sheets, no hidden
/// alternative path to learn.
struct SheetsPopover: View {
    @ObservedObject var store: DocumentStore
    @Binding var isPresented: Bool

    private var pinned: [VektorDocument] {
        store.documents
            .filter { $0.isPinned }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var others: [VektorDocument] {
        store.documents
            .filter { !$0.isPinned }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if pinned.isEmpty && others.isEmpty {
                emptyState
            } else {
                if !pinned.isEmpty {
                    sectionLabel("PINNED")
                    rowsList(pinned, shortcutPrefix: "⌘⇧")
                }

                if !pinned.isEmpty && !others.isEmpty {
                    Divider()
                        .overlay(VektorTheme.divider)
                        .padding(.vertical, 4)
                }

                if !others.isEmpty {
                    rowsList(others, shortcutPrefix: nil)
                }
            }
        }
        .padding(.vertical, 6)
        .frame(width: 320)
        .themedSheet()
    }

    // MARK: - Building blocks

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .tracking(1.4)
            .foregroundStyle(VektorTheme.muted)
            .padding(.horizontal, 18)
            .padding(.top, 6)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rowsList(_ docs: [VektorDocument], shortcutPrefix: String?) -> some View {
        VStack(spacing: 1) {
            ForEach(Array(docs.enumerated()), id: \.element.id) { index, doc in
                let shortcut: String? = {
                    guard let prefix = shortcutPrefix, index < 3 else { return nil }
                    return "\(prefix)\(index + 1)"
                }()
                SheetRow(
                    doc: doc,
                    isCurrent: doc.id == store.selectedID,
                    shortcut: shortcut,
                    onSelect: {
                        store.select(doc.id)
                        isPresented = false
                    },
                    onTogglePin: {
                        store.togglePinned(doc.id)
                    },
                    onDelete: {
                        store.delete(doc.id)
                    }
                )
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No sheets yet")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(VektorTheme.text)
            Text("Press ⌘N to create one.")
                .font(.caption)
                .foregroundStyle(VektorTheme.muted)
        }
        .padding(14)
    }
}

/// Single row in the SheetsPopover. Kept as a private struct so each
/// row can own its own `hovering` state — needed for the pin/trash
/// fade-in pattern that matches the rest of Vektor's chrome.
private struct SheetRow: View {
    let doc: VektorDocument
    let isCurrent: Bool
    let shortcut: String?
    let onSelect: () -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            pinButton

            Text(doc.title)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(isCurrent ? VektorTheme.accent : VektorTheme.text)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            if let shortcut {
                Text(shortcut)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(VektorTheme.muted)
            }

            trashButton
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isCurrent ? VektorTheme.surface : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .padding(.horizontal, 6)
        .contextMenu {
            Button(doc.isPinned ? "Unpin" : "Pin to top", action: onTogglePin)
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    private var pinButton: some View {
        Button(action: onTogglePin) {
            Image(systemName: doc.isPinned ? "pin.fill" : "pin")
                .font(.system(size: 9))
                .foregroundStyle(doc.isPinned ? VektorTheme.accent : VektorTheme.muted)
                .rotationEffect(.degrees(45))
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(doc.isPinned ? 1.0 : (hovering ? 1.0 : 0.35))
        .help(doc.isPinned ? "Unpin" : "Pin to top")
        .accessibilityLabel(doc.isPinned ? "Unpin \(doc.title)" : "Pin \(doc.title) to top")
    }

    private var trashButton: some View {
        Button(action: onDelete) {
            Image(systemName: "trash")
                .font(.system(size: 11))
                .foregroundStyle(VektorTheme.muted)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(hovering ? 1.0 : 0.35)
        .help("Delete sheet")
        .accessibilityLabel("Delete \(doc.title)")
    }
}
