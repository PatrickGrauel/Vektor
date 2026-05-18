import SwiftUI
import AppKit

/// Styled popover the notes editor uses for slash-command insertion.
/// Replaces NSTextView's stock `complete(_:)` system menu, which
/// looked like a context menu and broke the Bear-style aesthetic.
///
/// The popover lives across the editor's lifetime; show/hide is
/// gated by typed input. The owning coordinator drives the item list
/// and reads back the user's selection through the `commit` callback
/// on each item.

/// One row in the popover. Icon + title + (optional) subtitle.
/// Action fires when the user hits Return or clicks the row.
struct SuggestionItem: Identifiable {
    let id: String
    let icon: String
    let title: String
    let subtitle: String?
    let action: () -> Void
}

/// Not marked @MainActor — the editor coordinator that drives this
/// is formally nonisolated under strict concurrency. All callers are
/// on the main thread in practice (NSTextView delegate callbacks),
/// so the NSPopover access is safe; we just don't need the compile-
/// time isolation enforcement that would block the coordinator from
/// owning an instance.
final class SuggestionPopoverController: ObservableObject {
    @Published var items: [SuggestionItem] = []
    @Published var selectedIndex: Int = 0

    private let popover = NSPopover()

    init() {
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = NSHostingController(
            rootView: SuggestionListView(controller: self)
        )
    }

    var isShown: Bool { popover.isShown }

    func show(relativeTo rect: NSRect,
              of view: NSView,
              items: [SuggestionItem]) {
        self.items = items
        self.selectedIndex = 0
        if !popover.isShown {
            popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        }
    }

    func hide() {
        if popover.isShown {
            popover.close()
        }
    }

    /// Replace the item list (e.g. as the user types more characters
    /// after `/`, the filter narrows). Keeps the popover open;
    /// clamps the selection so it stays valid.
    func updateItems(_ next: [SuggestionItem]) {
        self.items = next
        self.selectedIndex = max(0, min(selectedIndex, next.count - 1))
    }

    func selectPrevious() {
        guard !items.isEmpty else { return }
        selectedIndex = max(0, selectedIndex - 1)
    }

    func selectNext() {
        guard !items.isEmpty else { return }
        selectedIndex = min(items.count - 1, selectedIndex + 1)
    }

    /// Fire the highlighted item's action and dismiss the popover.
    func commit() {
        guard items.indices.contains(selectedIndex) else { return }
        let item = items[selectedIndex]
        hide()
        item.action()
    }
}

private struct SuggestionListView: View {
    @ObservedObject var controller: SuggestionPopoverController

    var body: some View {
        VStack(spacing: 0) {
            if controller.items.isEmpty {
                Text("No matches")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(controller.items.enumerated()), id: \.element.id) { idx, item in
                    row(idx: idx, item: item)
                }
            }
        }
        .frame(width: 280)
        .padding(.vertical, 4)
    }

    private func row(idx: Int, item: SuggestionItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.icon)
                .foregroundStyle(TallyTheme.accent)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(TallyTheme.text)
                if let sub = item.subtitle {
                    Text(sub)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(idx == controller.selectedIndex
                    ? TallyTheme.accent.opacity(0.18)
                    : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            controller.selectedIndex = idx
            controller.commit()
        }
    }
}
