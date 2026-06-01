import SwiftUI

/// Shared building blocks for the Finance forms — labeled numeric inputs and
/// result tiles, styled to the Vektor theme. Plain SwiftUI, touch-friendly.

/// A labeled decimal input row for use inside a `Form`/`Section`.
struct NumberField: View {
    let label: String
    @Binding var value: Double
    var suffix: String = ""

    var body: some View {
        HStack {
            Text(label).foregroundStyle(VektorTheme.text)
            Spacer(minLength: 12)
            TextField("", value: $value, format: .number.precision(.fractionLength(0...2)))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(maxWidth: 130)
            if !suffix.isEmpty {
                Text(suffix).font(.caption).foregroundStyle(VektorTheme.muted)
            }
        }
    }
}

/// A labeled integer input via a stepper (good for ages, years, counts).
struct IntStepperField: View {
    let label: String
    @Binding var value: Int
    var range: ClosedRange<Int> = 0...100
    var suffix: String = ""

    var body: some View {
        Stepper(value: $value, in: range) {
            HStack {
                Text(label).foregroundStyle(VektorTheme.text)
                Spacer()
                Text("\(value)\(suffix.isEmpty ? "" : " \(suffix)")")
                    .monospacedDigit()
                    .foregroundStyle(VektorTheme.muted)
            }
        }
    }
}

/// 3-letter currency code field, uppercased as you type.
struct CurrencyField: View {
    @Binding var code: String
    var body: some View {
        HStack {
            Text("Currency").foregroundStyle(VektorTheme.text)
            Spacer()
            TextField("EUR", text: $code)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 80)
                .onChange(of: code) { _, new in
                    let up = String(new.uppercased().prefix(3))
                    if up != code { code = up }
                }
        }
    }
}

/// A result tile: small uppercase title, prominent value, optional hint.
struct MetricBox: View {
    let title: String
    let value: String
    var tone: Tone = .neutral
    var hint: String? = nil

    enum Tone {
        case good, caution, bad, accent, neutral
        var color: Color {
            switch self {
            case .good:    return VektorTheme.statusGood
            case .caution: return VektorTheme.statusCaution
            case .bad:     return VektorTheme.statusBad
            case .accent:  return VektorTheme.accent
            case .neutral: return VektorTheme.text
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(VektorTheme.muted)
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(tone.color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let hint {
                Text(hint).font(.caption2).foregroundStyle(VektorTheme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(VektorTheme.surface, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// A 2-column grid of metric tiles.
struct MetricGrid<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                            GridItem(.flexible(), spacing: 10)], spacing: 10) {
            content
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        .listRowBackground(Color.clear)
    }
}
