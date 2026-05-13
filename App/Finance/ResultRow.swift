import SwiftUI

/// Wraps a `LabeledContent` value with a trailing arrow button that copies
/// the bare value into the active Calculator document. Keeps every result
/// row consistent across the Finance forms without each one re-implementing
/// the button.
struct ResultRow: View {
    @EnvironmentObject private var calc: CalculatorBridge
    let label: String
    let value: String
    /// Override the value sent to the calculator (e.g. the underlying
    /// number without the currency suffix). Falls back to `value`.
    var sendable: String? = nil
    var emphasised: Bool = false

    @State private var hovering = false

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                Text(value)
                    .font(emphasised ? .headline : .body)
                    .foregroundStyle(TallyTheme.text)
                    .monospacedDigit()
                Button {
                    calc.send(label, sendable ?? value)
                } label: {
                    Image(systemName: "arrow.right.circle")
                        .foregroundStyle(hovering ? TallyTheme.text : TallyTheme.muted)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .help("Send \(label.lowercased()) to Calculator")
                .accessibilityLabel("Send \(label) to Calculator")
            }
        }
    }
}
