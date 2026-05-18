import SwiftUI

/// Shared layout primitives the Finance pane's forms reuse. Pulled
/// out of `LoanForm` / `RealEstateForm` so the new tools (savings,
/// retirement, subscriptions, travel, inflation) don't each
/// re-implement the same metric box / labelled slider / section header.

// MARK: - Metric box

/// Single coloured metric tile used on dashboards. Value is the
/// large reading, label is the small caption underneath, hint is
/// optional supplementary text shown muted in the corner.
struct MetricBox: View {
    let value: String
    let label: String
    var hint: String? = nil
    var tone: Tone = .neutral

    enum Tone { case good, caution, bad, neutral, accent
        var color: Color {
            switch self {
            case .good:     return TallyTheme.statusGood
            case .caution:  return TallyTheme.statusCaution
            case .bad:      return TallyTheme.statusBad
            case .accent:   return TallyTheme.accent
            case .neutral:  return TallyTheme.text
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(TallyTheme.muted)
                Spacer()
                if let hint {
                    Text(hint)
                        .font(.caption2)
                        .foregroundStyle(TallyTheme.muted)
                }
            }
            Text(value)
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .foregroundStyle(tone.color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TallyTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Labelled slider with numeric read-out

/// Slider + numeric field side-by-side. Used everywhere across
/// Finance — extracted so the form code stays focused on the math,
/// not the layout.
struct LabelledSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    /// Format the numeric read-out (e.g. `"%.0f%%"`, `"%.2f"`).
    var format: String = "%.0f"
    /// Optional unit suffix appended to the slider's right side.
    var unit: String? = nil

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Slider(value: $value, in: range, step: step)
                Text(String(format: format, value) + (unit.map { " \($0)" } ?? ""))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(TallyTheme.text)
                    .frame(width: 90, alignment: .trailing)
            }
        } label: {
            Text(label)
                .foregroundStyle(TallyTheme.muted)
        }
    }
}

// MARK: - Form section header

/// Small uppercase section title used between input groups so a
/// long form doesn't read like one wall of fields.
struct FormSectionHeader: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(TallyTheme.muted)
            .padding(.top, 4)
    }
}

// MARK: - Currency picker

/// Compact 3-letter currency picker. Free-form text field with
/// uppercase coercion so the user can type any ISO code without
/// us having to maintain an exhaustive list.
struct CurrencyField: View {
    @Binding var code: String
    var width: CGFloat = 70
    var body: some View {
        TextField("", text: $code, prompt: Text("EUR"))
            .textFieldStyle(.roundedBorder)
            .frame(width: width)
            .onChange(of: code) { _, new in
                let upper = String(new.prefix(3)).uppercased()
                if upper != new { code = upper }
            }
    }
}
