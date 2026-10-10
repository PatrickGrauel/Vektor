import SwiftUI

/// Compact labeled numeric input used across all E6B tabs. Trailing
/// suffix label, an inline stepper, and a fixed-width text field so a
/// column of these stays aligned. Use `ClampedNumericField` from
/// `SharedUI.swift` directly when the value must clamp at commit time
/// (e.g. course = 999° in aviation); this field is for the lighter
/// "type-and-step" case. Typed values outside `range` are clamped on
/// commit, so keep ranges wide enough for any real input.
struct NumericField: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...100_000
    var step: Double = 1
    var suffix: String = ""
    var format: FloatingPointFormatStyle<Double> = .number.precision(.fractionLength(0...2))

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField("", value: $value, format: format)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 86)
                    .multilineTextAlignment(.trailing)
                if !suffix.isEmpty {
                    Text(suffix).foregroundStyle(.secondary).font(.caption)
                }
                Stepper("", value: $value, in: range, step: step)
                    .labelsHidden()
            }
        }
        .onChange(of: value) { _, v in
            let clamped = v.isFinite ? min(max(v, range.lowerBound), range.upperBound) : range.lowerBound
            if clamped != v { value = clamped }
        }
    }
}
