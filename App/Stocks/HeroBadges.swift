import SwiftUI

/// Three small chip-style badges shown next to the symbol and the
/// score in the Stocks pane hero verdict: current price, trailing
/// one-month change, and a fair-value verdict derived from the stock's
/// P/E vs its sector's average P/E on the same exchange.
///
/// Visual pattern follows `Sparkline.directionChip` (line 73 of
/// Sparkline.swift): a small capsule with `colour.opacity(0.12)`
/// background and the matching `TallyTheme.status*` foreground. The
/// dual-channel rule (icon + colour) is preserved on the change and
/// fair-value badges so red-green deficiency users still get the signal.

/// One-month price change badge. Green up-arrow if ≥ 0, red down-arrow
/// otherwise. Stable at exactly 0 (rare in practice) uses the muted
/// "flat" arrow.
struct ChangeBadge: View {
    let percent: Double   // 0.042 == +4.2%

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
            Text(formatted)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
        }
        .foregroundStyle(colour)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(colour.opacity(0.12))
        .clipShape(Capsule())
        .accessibilityLabel("One month change \(formatted)")
    }

    private var symbol: String {
        if percent > 0.0005   { return "arrow.up.right" }
        if percent < -0.0005  { return "arrow.down.right" }
        return "arrow.right"
    }
    private var colour: Color {
        if percent > 0.0005   { return TallyTheme.statusGood }
        if percent < -0.0005  { return TallyTheme.statusBad }
        return TallyTheme.muted
    }
    private var formatted: String {
        let pct = percent * 100
        let sign = pct > 0 ? "+" : ""
        return "\(sign)\(String(format: "%.1f", pct))% · 1M"
    }
}

/// Securities-identifier chip — WKN / ISIN / CUSIP. Same capsule shape
/// as the other badges but a neutral colour so the catalogue codes
/// don't compete for attention with the price + change.
struct IdentifierChip: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(TallyTheme.muted)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(TallyTheme.text)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(TallyTheme.codeSurface)
        .clipShape(Capsule())
        .accessibilityLabel("\(label) \(value)")
    }
}

/// Fair-value verdict badge. Green when underpriced (PE < 85% of
/// sector average), red when overpriced (PE > 115%), neutral when
/// inside the ±15% band. Tooltip exposes the raw P/E and sector P/E
/// so the user can see the math.
struct FairValueBadge: View {
    let verdict: FairValue
    let peRatio: Double?
    let sectorPE: Double?
    let sector: String?

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
        }
        .foregroundStyle(colour)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(colour.opacity(0.12))
        .clipShape(Capsule())
        .help(tooltip)
        .accessibilityLabel(label)
    }

    private var symbol: String {
        switch verdict {
        case .underpriced: return "arrow.down.circle.fill"
        case .fair:        return "equal.circle.fill"
        case .overpriced:  return "arrow.up.circle.fill"
        case .unknown:     return "questionmark.circle"
        }
    }
    private var colour: Color {
        switch verdict {
        case .underpriced: return TallyTheme.statusGood
        case .fair:        return TallyTheme.muted
        case .overpriced:  return TallyTheme.statusBad
        case .unknown:     return TallyTheme.muted
        }
    }
    private var label: String {
        switch verdict {
        case .underpriced: return "Underpriced"
        case .fair:        return "Fair"
        case .overpriced:  return "Overpriced"
        case .unknown:     return "P/E n/a"
        }
    }
    private var tooltip: String {
        guard let pe = peRatio, let sp = sectorPE else {
            return "Sector or company P/E not available — fair-value verdict unavailable."
        }
        let sec = sector ?? "sector"
        return String(format: "P/E %.1f vs %@ avg %.1f — threshold ±15%%", pe, sec, sp)
    }
}
