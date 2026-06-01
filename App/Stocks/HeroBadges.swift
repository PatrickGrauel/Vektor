import SwiftUI
import AppKit

/// Three small chip-style badges shown next to the symbol and the
/// score in the Stocks pane hero verdict: current price, trailing
/// one-month change, and a fair-value verdict derived from the stock's
/// P/E vs its sector's average P/E on the same exchange.
///
/// Visual pattern follows `Sparkline.directionChip` (line 73 of
/// Sparkline.swift): a small capsule with `colour.opacity(0.12)`
/// background and the matching `VektorTheme.status*` foreground. The
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
        if percent > 0.0005   { return VektorTheme.statusGood }
        if percent < -0.0005  { return VektorTheme.statusBad }
        return VektorTheme.muted
    }
    private var formatted: String {
        let pct = percent * 100
        let sign = pct > 0 ? "+" : ""
        return "\(sign)\(String(format: "%.1f", pct))% · 1M"
    }
}

/// Securities-identifier chip — WKN / ISIN / CUSIP. Same capsule shape
/// as the other badges but a neutral colour so the catalogue codes
/// don't compete for attention with the price + change. Click anywhere
/// on the chip to copy the value to the clipboard — common workflow
/// for German investors pasting an ISIN into a broker search box.
/// Brief "Copied" flash gives feedback that the click landed.
struct IdentifierChip: View {
    let label: String
    let value: String

    @State private var justCopied: Bool = false

    var body: some View {
        Button(action: copy) {
            HStack(spacing: 3) {
                Text(justCopied ? "Copied" : label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(justCopied ? VektorTheme.statusGood : VektorTheme.muted)
                Text(value)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(VektorTheme.text)
                Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(justCopied ? VektorTheme.statusGood : VektorTheme.muted)
                    .padding(.leading, 1)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(VektorTheme.codeSurface)
            .clipShape(Capsule())
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Click to copy \(label) — \(value)")
        .accessibilityLabel("\(label) \(value). Click to copy.")
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        // Brief "Copied" flash so the user sees the click landed.
        withAnimation(.easeOut(duration: 0.15)) { justCopied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            await MainActor.run {
                withAnimation(.easeIn(duration: 0.25)) { justCopied = false }
            }
        }
    }
}

/// Upcoming-earnings chip — date + countdown ("Aug 26 · in 12 days").
/// Tints amber when the announcement is within a week (high-event-risk
/// window when buying or holding usually warrants extra thought) and
/// muted otherwise. Tooltip exposes the exact ISO date/time.
struct EarningsBadge: View {
    let date: Date

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "calendar")
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
        .accessibilityLabel("Next earnings \(label)")
    }

    private var daysUntil: Int {
        let cal = Calendar(identifier: .gregorian)
        let now = cal.startOfDay(for: Date())
        let then = cal.startOfDay(for: date)
        return cal.dateComponents([.day], from: now, to: then).day ?? 0
    }

    private var label: String {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        f.locale = Locale(identifier: "en_US_POSIX")
        let datePart = f.string(from: date)
        let n = daysUntil
        let countdown: String
        switch n {
        case 0:   countdown = "today"
        case 1:   countdown = "tomorrow"
        default:  countdown = "in \(n) days"
        }
        return "\(datePart) · \(countdown)"
    }

    private var colour: Color {
        // Within a week → amber; further out → muted neutral. Past
        // dates shouldn't reach here (parser already filters them).
        daysUntil <= 7 ? VektorTheme.statusCaution : VektorTheme.muted
    }

    private var tooltip: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, d MMM yyyy 'at' HH:mm zzz"
        f.locale = Locale(identifier: "en_US_POSIX")
        return "Next earnings announcement: \(f.string(from: date))"
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
        case .underpriced: return VektorTheme.statusGood
        case .fair:        return VektorTheme.muted
        case .overpriced:  return VektorTheme.statusBad
        case .unknown:     return VektorTheme.muted
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
