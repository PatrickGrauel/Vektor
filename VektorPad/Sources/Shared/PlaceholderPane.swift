import SwiftUI

/// Stand-in for a module pane that hasn't been rebuilt for touch yet. The
/// engine that powers each of these is already linked (shared package), so
/// filling them in is UI-only work.
struct PlaceholderPane: View {
    let pane: Pane

    var body: some View {
        ContentUnavailableView {
            Label(pane.rawValue, systemImage: pane.icon)
        } description: {
            VStack(spacing: 6) {
                Text("Coming to the iPad version.")
                if !pane.moduleDescription.isEmpty {
                    Text(pane.moduleDescription)
                        .font(.footnote)
                        .foregroundStyle(VektorTheme.muted)
                }
            }
        }
        .navigationTitle(pane.rawValue)
        .navigationBarTitleDisplayMode(.inline)
        .background(VektorTheme.background)
    }
}
