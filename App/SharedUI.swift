import SwiftUI

// MARK: - Status palette + badge
//
// Three semantic levels — good / caution / bad — wired to the theme
// tokens in `Theme.swift`. Always paired with an SF Symbol so the
// signal isn't colour-only (red-green deficiency, monochrome
// printing, low-end displays).

enum StatusLevel: Equatable {
    case good, caution, bad, neutral

    var colour: Color {
        switch self {
        case .good:     return TallyTheme.statusGood
        case .caution:  return TallyTheme.statusCaution
        case .bad:      return TallyTheme.statusBad
        case .neutral:  return TallyTheme.muted
        }
    }

    var symbol: String {
        switch self {
        case .good:     return "checkmark.circle.fill"
        case .caution:  return "exclamationmark.triangle.fill"
        case .bad:      return "xmark.octagon.fill"
        case .neutral:  return "minus.circle.fill"
        }
    }

    var label: String {
        switch self {
        case .good:     return "good"
        case .caution:  return "caution"
        case .bad:      return "bad"
        case .neutral:  return "neutral"
        }
    }
}

/// Small leading symbol + matching colour, used inside dashboard tiles
/// and any other place a status verdict needs to be both visible AND
/// accessible.
struct StatusBadge: View {
    let level: StatusLevel
    var body: some View {
        Image(systemName: level.symbol)
            .foregroundStyle(level.colour)
            .accessibilityLabel(level.label)
    }
}

// MARK: - Clamped numeric input
//
// Replaces every TextField-with-format-number-paired-with-a-Slider
// across the form panes. Clamps to the slider's range on commit so
// `course = 999°` (E6B) and `weight = -50` (W&B) can't propagate into
// downstream math. Locale-aware (POSIX) so comma/period quirks don't
// silently mis-parse.

struct ClampedNumericField: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var width: CGFloat = 80
    var format: FloatingPointFormatStyle<Double> = .number

    var body: some View {
        TextField("", value: $value, format: format)
            .textFieldStyle(.roundedBorder)
            .frame(width: width)
            .onSubmit { value = clamp(value) }
            .onChange(of: value) { _, new in
                // Defer the clamp to the next runloop tick so the user can
                // type a transient digit-by-digit value (e.g. "1" before
                // "100") without being snapped backwards as they type.
                let clamped = clamp(new)
                if clamped != new {
                    DispatchQueue.main.async { value = clamped }
                }
            }
    }

    private func clamp(_ v: Double) -> Double {
        if v.isNaN || !v.isFinite { return range.lowerBound }
        return min(max(v, range.lowerBound), range.upperBound)
    }
}

/// Integer version with the same semantics — wraps a `Double`-backed
/// binding so callers don't have to juggle the type at every site, and
/// rounds the display.
struct ClampedIntegerField: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var width: CGFloat = 80

    var body: some View {
        TextField("", value: $value, format: .number.precision(.fractionLength(0)))
            .textFieldStyle(.roundedBorder)
            .frame(width: width)
            .onSubmit { value = clamp(value) }
            .onChange(of: value) { _, new in
                let clamped = clamp(new.rounded())
                if clamped != new {
                    DispatchQueue.main.async { value = clamped }
                }
            }
    }

    private func clamp(_ v: Double) -> Double {
        if v.isNaN || !v.isFinite { return range.lowerBound.rounded() }
        return min(max(v.rounded(), range.lowerBound), range.upperBound)
    }
}
