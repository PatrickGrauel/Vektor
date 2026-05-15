import SwiftUI

/// Per-axis drill-down view. Built to render one or many companies on
/// the same chart so the upcoming compare feature (KO vs PEP vs KDP)
/// drops in without a refactor — `slices` is an array, single-company
/// mode just passes one.
///
/// Layered surfaces:
///   1. The primary time-series chart with Buffett's threshold bands.
///      For same-units composite axes (Cost Discipline) this chart
///      carries multiple lines so the user sees which input drives
///      the score — fixing the "SG&A looks great but R&D tanks it"
///      blind spot the single-line chart had.
///   2. For mixed-units composites (Balance Sheet, Capital Allocation):
///      stacked sub-charts beneath the primary, each with its own
///      Y-axis and thresholds.
///   3. A wide year-by-year table — primary metric plus all extras.
///   4. (Composite axes only) the score breakdown — how each input
///      contributed to the total.
struct AxisDetailView: View {
    let axis: Axis
    let slices: [Slice]

    /// One company's contribution to an axis. For single-company mode
    /// this array has one element; for compare it has 2–3.
    struct Slice: Identifiable {
        let symbol: String
        let score: AxisScore
        let color: Color
        var id: String { symbol }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            primaryChartCard
            multiLineLegend                   // visible only when extras are on the primary chart
            thresholdLegend                   // primary thresholds
            extraStackedCharts                // mixed-units secondary charts
            yearByYearTable
            breakdownCard
        }
        .padding(.top, 6)
    }

    // MARK: - Primary chart

    private var primaryChartCard: some View {
        AxisChartCanvas(
            slices: slices,
            thresholds: slices.first?.score.thresholds ?? [],
            extraLines: slices.count == 1 ? (slices.first?.score.extraLines ?? []) : []
        )
        .frame(height: 140)
    }

    /// Legend for the multi-line primary chart. Hidden when there's
    /// only the primary line — the radar already labels that.
    @ViewBuilder
    private var multiLineLegend: some View {
        if slices.count == 1,
           let primary = slices.first,
           let extras = primary.score.extraLines, !extras.isEmpty,
           let trend = primary.score.trend {
            HStack(spacing: 14) {
                lineLegendItem(label: axis.primaryLineLabel,
                               color: primary.color,
                               target: nil,
                               format: trend.format)
                ForEach(extras) { line in
                    lineLegendItem(label: line.label,
                                   color: line.color,
                                   target: line.target,
                                   format: trend.format)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func lineLegendItem(label: String, color: Color, target: Double?,
                                format: (Double) -> String) -> some View {
        HStack(spacing: 5) {
            Rectangle().fill(color).frame(width: 12, height: 2)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(TallyTheme.text)
            if let t = target {
                Text("target ≤\(format(t))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Legend for the threshold bands behind the primary chart.
    @ViewBuilder
    private var thresholdLegend: some View {
        if let primary = slices.first?.score, !primary.thresholds.isEmpty,
           // Only show threshold legend on single-line charts. The
           // multi-line composite chart drops band tinting (different
           // metrics have different cutoffs), so this legend would be
           // misleading there.
           (slices.first?.score.extraLines?.isEmpty ?? true) {
            HStack(spacing: 12) {
                ForEach(Array(primary.thresholds.enumerated()), id: \.offset) { _, t in
                    HStack(spacing: 5) {
                        Rectangle().fill(t.tier.colour).frame(width: 10, height: 2)
                        Text(t.label)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Stacked sub-charts (mixed-units composites)

    @ViewBuilder
    private var extraStackedCharts: some View {
        if slices.count == 1, let primary = slices.first,
           let extras = primary.score.extraCharts, !extras.isEmpty {
            ForEach(extras) { chart in
                VStack(alignment: .leading, spacing: 6) {
                    Text(chart.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    AxisSubChartCanvas(
                        trend: chart.trend,
                        thresholds: chart.thresholds,
                        color: primary.color
                    )
                    .frame(height: 90)
                    if !chart.thresholds.isEmpty {
                        HStack(spacing: 12) {
                            ForEach(Array(chart.thresholds.enumerated()), id: \.offset) { _, t in
                                HStack(spacing: 5) {
                                    Rectangle().fill(t.tier.colour).frame(width: 10, height: 2)
                                    Text(t.label)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Year-by-year table

    @ViewBuilder
    private var yearByYearTable: some View {
        if let years = slices.first?.score.trend?.years, !years.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                tableHeader
                Divider().opacity(0.3)
                ForEach(Array(years.enumerated()), id: \.offset) { idx, year in
                    tableRow(for: idx, year: year)
                }
            }
            .padding(10)
            .background(TallyTheme.codeSurface.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    @ViewBuilder
    private var tableHeader: some View {
        HStack(spacing: 0) {
            Text("Year")
                .frame(width: 60, alignment: .leading)
            ForEach(slices) { s in
                let label = slices.count == 1
                    ? axis.primaryLineLabel
                    : s.symbol
                Text(label)
                    .foregroundStyle(s.color)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                if slices.count == 1, let extras = s.score.extraLines {
                    ForEach(extras) { line in
                        Text(line.label)
                            .foregroundStyle(line.color)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func tableRow(for idx: Int, year: Int) -> some View {
        HStack(spacing: 0) {
            Text(String(year))
                .frame(width: 60, alignment: .leading)
                .foregroundStyle(.secondary)
            ForEach(slices) { s in
                cellText(value: s.score.trend?.values[safe: idx],
                         format: s.score.trend?.format)
                if slices.count == 1, let extras = s.score.extraLines {
                    ForEach(extras) { line in
                        cellText(value: line.values[safe: idx],
                                 format: s.score.trend?.format)
                    }
                }
            }
        }
        .font(.system(.caption, design: .monospaced))
    }

    private func cellText(value: Double?, format: ((Double) -> String)?) -> some View {
        let text: String
        if let v = value, let f = format {
            text = f(v)
        } else if let v = value {
            text = String(format: "%.2f", v)
        } else {
            text = "—"
        }
        return Text(text)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .foregroundStyle(value == nil ? .secondary : TallyTheme.text)
    }

    // MARK: - Breakdown

    @ViewBuilder
    private var breakdownCard: some View {
        if let primary = slices.first?.score, let breakdown = primary.breakdown {
            VStack(alignment: .leading, spacing: 4) {
                Text("Score breakdown")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 2)
                ForEach(Array(breakdown.enumerated()), id: \.offset) { _, line in
                    let isTotal = line.contains("Total")
                    Text(line)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(isTotal ? TallyTheme.accent : TallyTheme.text)
                        .fontWeight(isTotal ? .semibold : .regular)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TallyTheme.codeSurface.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

// MARK: - Axis primary line label

private extension Axis {
    /// What to call the primary line of an axis when its label is shown
    /// (legend, table column header). The axis name is too generic
    /// ("Pricing Power" instead of "GPM"); this is the metric label.
    var primaryLineLabel: String {
        switch self {
        case .pricingPower:      return "GPM"
        case .costDiscipline:    return "SG&A"
        case .earningsQuality:   return "Net margin"
        case .capitalEfficiency: return "Adj ROE"
        case .balanceSheet:      return "D/E"
        case .capitalAllocation: return "CapEx ratio"
        }
    }
}

// MARK: - Primary chart canvas

/// The big chart in the drill-down. Threshold bands drawn first (tinted
/// regions between cutoffs) — except when extra lines are present, which
/// would make the bands misleading (different metrics, different
/// cutoffs). Then threshold lines on top, then one polyline per slice
/// for compare mode, then any extra same-units lines.
private struct AxisChartCanvas: View {
    let slices: [AxisDetailView.Slice]
    let thresholds: [AxisThreshold]
    let extraLines: [AxisLine]

    var body: some View {
        Canvas { context, size in
            guard let primary = slices.first?.score.trend else { return }
            let yearCount = primary.years.count
            guard yearCount >= 2 else { return }

            let isMultiLine = !extraLines.isEmpty

            // Y-range: encompass primary values, extra-line values, and
            // (for single-line charts) threshold cutoffs so bands stay
            // visible. Multi-line charts skip threshold-driven scaling.
            var allValues: [Double] = []
            for s in slices { allValues.append(contentsOf: s.score.trend?.values ?? []) }
            for l in extraLines { allValues.append(contentsOf: l.values) }
            if !isMultiLine { allValues.append(contentsOf: thresholds.map(\.value)) }
            let minV = allValues.min() ?? 0
            let maxV = allValues.max() ?? 1
            let span = max(maxV - minV, 0.0001) * 1.20
            let lo = minV - span * 0.10
            let hi = lo + span

            let chartRect = CGRect(
                x: 40, y: 6,
                width: size.width - 50,
                height: size.height - 24
            )

            func xFor(_ i: Int) -> CGFloat {
                let t = yearCount == 1 ? 0.5 : Double(i) / Double(yearCount - 1)
                return chartRect.minX + chartRect.width * CGFloat(t)
            }
            func yFor(_ v: Double) -> CGFloat {
                let t = (v - lo) / (hi - lo)
                return chartRect.maxY - chartRect.height * CGFloat(t)
            }

            // 1. Threshold bands — ONLY in single-line mode. For multi-
            //    line composites the primary's bands don't apply to the
            //    other lines (R&D's good range ≠ SG&A's good range), so
            //    we drop the tinting to avoid misleading the reader.
            if !isMultiLine && !thresholds.isEmpty {
                let betterIsHigher = primary.betterIsHigher
                let sortedDescending = thresholds.sorted { $0.value > $1.value }
                for (idx, t) in sortedDescending.enumerated() {
                    let upperValue: Double = (idx == 0) ? hi : sortedDescending[idx - 1].value
                    let lowerValue: Double = t.value
                    let bandTop = yFor(upperValue)
                    let bandBottom = yFor(lowerValue)
                    let bandRect = CGRect(
                        x: chartRect.minX, y: min(bandTop, bandBottom),
                        width: chartRect.width,
                        height: abs(bandBottom - bandTop)
                    )
                    let bandTier: ScoreTier = betterIsHigher
                        ? t.tier
                        : flipTier(t.tier)
                    context.fill(
                        Path(bandRect),
                        with: .color(bandTier.colour.opacity(0.07))
                    )
                }
                if let topThreshold = sortedDescending.first {
                    let topRect = CGRect(
                        x: chartRect.minX, y: chartRect.minY,
                        width: chartRect.width,
                        height: yFor(topThreshold.value) - chartRect.minY
                    )
                    let bestTier: ScoreTier = betterIsHigher ? .strong : .weak
                    context.fill(Path(topRect),
                                 with: .color(bestTier.colour.opacity(0.07)))
                }
                if let bottomThreshold = sortedDescending.last {
                    let bottomRect = CGRect(
                        x: chartRect.minX, y: yFor(bottomThreshold.value),
                        width: chartRect.width,
                        height: chartRect.maxY - yFor(bottomThreshold.value)
                    )
                    let worstTier: ScoreTier = betterIsHigher ? .weak : .strong
                    context.fill(Path(bottomRect),
                                 with: .color(worstTier.colour.opacity(0.07)))
                }

                // Threshold dashed lines + Y-axis tick labels — same as
                // single-line version.
                for t in thresholds {
                    let y = yFor(t.value)
                    var p = Path()
                    p.move(to: CGPoint(x: chartRect.minX, y: y))
                    p.addLine(to: CGPoint(x: chartRect.maxX, y: y))
                    context.stroke(p, with: .color(t.tier.colour.opacity(0.5)),
                                   style: StrokeStyle(lineWidth: 0.6, dash: [3, 3]))
                    let label = Text(primary.format(t.value))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(TallyTheme.muted)
                    context.draw(label, at: CGPoint(x: chartRect.minX - 6, y: y),
                                 anchor: .trailing)
                }
            } else if isMultiLine {
                // Multi-line: per-line target lines in each line's own
                // color, drawn as faint full-width dashed strokes. This
                // gives the reader each metric's own benchmark without
                // the misleading band tinting.
                if let primary = slices.first {
                    drawTargetLine(in: context, chartRect: chartRect,
                                   yFor: yFor,
                                   value: primary.score.trend.flatMap { _ in
                                       // The primary's "target" is its
                                       // strongest threshold's value.
                                       thresholds.sorted { $0.value > $1.value }
                                           .first(where: { $0.tier == .strong })?.value
                                   } ?? 0,
                                   color: primary.color)
                }
                for line in extraLines {
                    if let target = line.target {
                        drawTargetLine(in: context, chartRect: chartRect,
                                       yFor: yFor, value: target, color: line.color)
                    }
                }
            }

            // 2. X-axis year labels.
            for (i, year) in primary.years.enumerated() {
                let x = xFor(i)
                let suffix = year % 100
                let label = Text(String(format: "%02d", suffix))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(TallyTheme.muted)
                context.draw(label, at: CGPoint(x: x, y: chartRect.maxY + 10),
                             anchor: .center)
            }

            // 3. Data lines — one per slice (compare mode) plus any
            //    extra metric lines (single-company composite).
            for slice in slices {
                if let trend = slice.score.trend {
                    drawSeries(in: context, values: trend.values,
                               yFor: yFor, xFor: xFor, color: slice.color)
                }
            }
            for line in extraLines {
                drawSeries(in: context, values: line.values,
                           yFor: yFor, xFor: xFor, color: line.color)
            }
        }
    }

    private func drawSeries(
        in context: GraphicsContext,
        values: [Double],
        yFor: (Double) -> CGFloat,
        xFor: (Int) -> CGFloat,
        color: Color
    ) {
        var path = Path()
        for (i, v) in values.enumerated() {
            let p = CGPoint(x: xFor(i), y: yFor(v))
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        context.stroke(path, with: .color(color), lineWidth: 1.8)
        for (i, v) in values.enumerated() {
            let p = CGPoint(x: xFor(i), y: yFor(v))
            let dot = Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3,
                                             width: 6, height: 6))
            context.fill(dot, with: .color(color))
        }
    }

    private func drawTargetLine(
        in context: GraphicsContext,
        chartRect: CGRect,
        yFor: (Double) -> CGFloat,
        value: Double,
        color: Color
    ) {
        let y = yFor(value)
        var p = Path()
        p.move(to: CGPoint(x: chartRect.minX, y: y))
        p.addLine(to: CGPoint(x: chartRect.maxX, y: y))
        context.stroke(p, with: .color(color.opacity(0.35)),
                       style: StrokeStyle(lineWidth: 0.6, dash: [2, 3]))
    }

    private func flipTier(_ t: ScoreTier) -> ScoreTier {
        switch t {
        case .strong: return .weak
        case .weak:   return .strong
        default:      return t
        }
    }
}

// MARK: - Stacked sub-chart (different units)

/// Mini single-metric chart used to render stacked sub-charts beneath
/// the primary, for composites whose inputs have different units.
/// Logic mirrors the single-line branch of AxisChartCanvas — bands
/// tinted between thresholds, dashed cutoff lines, polyline + dots.
private struct AxisSubChartCanvas: View {
    let trend: AxisTrend
    let thresholds: [AxisThreshold]
    let color: Color

    var body: some View {
        Canvas { context, size in
            let yearCount = trend.years.count
            guard yearCount >= 2 else { return }
            var allValues = trend.values
            allValues.append(contentsOf: thresholds.map(\.value))
            let minV = allValues.min() ?? 0
            let maxV = allValues.max() ?? 1
            let span = max(maxV - minV, 0.0001) * 1.20
            let lo = minV - span * 0.10
            let hi = lo + span

            let chartRect = CGRect(
                x: 40, y: 4,
                width: size.width - 50,
                height: size.height - 20
            )

            func xFor(_ i: Int) -> CGFloat {
                let t = Double(i) / Double(yearCount - 1)
                return chartRect.minX + chartRect.width * CGFloat(t)
            }
            func yFor(_ v: Double) -> CGFloat {
                let t = (v - lo) / (hi - lo)
                return chartRect.maxY - chartRect.height * CGFloat(t)
            }

            // Threshold bands (same logic as primary, simplified).
            if !thresholds.isEmpty {
                let sortedDescending = thresholds.sorted { $0.value > $1.value }
                for (idx, t) in sortedDescending.enumerated() {
                    let upperValue: Double = (idx == 0) ? hi : sortedDescending[idx - 1].value
                    let lowerValue: Double = t.value
                    let bandTop = yFor(upperValue)
                    let bandBottom = yFor(lowerValue)
                    let rect = CGRect(
                        x: chartRect.minX, y: min(bandTop, bandBottom),
                        width: chartRect.width,
                        height: abs(bandBottom - bandTop)
                    )
                    let tier: ScoreTier = trend.betterIsHigher
                        ? t.tier
                        : flipTier(t.tier)
                    context.fill(Path(rect),
                                 with: .color(tier.colour.opacity(0.07)))
                }
                if let top = sortedDescending.first {
                    let rect = CGRect(x: chartRect.minX, y: chartRect.minY,
                                      width: chartRect.width,
                                      height: yFor(top.value) - chartRect.minY)
                    let bestTier: ScoreTier = trend.betterIsHigher ? .strong : .weak
                    context.fill(Path(rect),
                                 with: .color(bestTier.colour.opacity(0.07)))
                }
                if let bot = sortedDescending.last {
                    let rect = CGRect(x: chartRect.minX, y: yFor(bot.value),
                                      width: chartRect.width,
                                      height: chartRect.maxY - yFor(bot.value))
                    let worstTier: ScoreTier = trend.betterIsHigher ? .weak : .strong
                    context.fill(Path(rect),
                                 with: .color(worstTier.colour.opacity(0.07)))
                }
                for t in thresholds {
                    let y = yFor(t.value)
                    var p = Path()
                    p.move(to: CGPoint(x: chartRect.minX, y: y))
                    p.addLine(to: CGPoint(x: chartRect.maxX, y: y))
                    context.stroke(p, with: .color(t.tier.colour.opacity(0.5)),
                                   style: StrokeStyle(lineWidth: 0.6, dash: [3, 3]))
                    let label = Text(trend.format(t.value))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(TallyTheme.muted)
                    context.draw(label,
                                 at: CGPoint(x: chartRect.minX - 6, y: y),
                                 anchor: .trailing)
                }
            } else {
                // No thresholds: still want Y-axis hints — show min and
                // max so the reader can read the slope.
                for v in [maxV, minV] {
                    let label = Text(trend.format(v))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(TallyTheme.muted)
                    context.draw(label,
                                 at: CGPoint(x: chartRect.minX - 6, y: yFor(v)),
                                 anchor: .trailing)
                }
            }

            // X-axis year labels.
            for (i, year) in trend.years.enumerated() {
                let x = xFor(i)
                let suffix = year % 100
                let label = Text(String(format: "%02d", suffix))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(TallyTheme.muted)
                context.draw(label, at: CGPoint(x: x, y: chartRect.maxY + 8),
                             anchor: .center)
            }

            // Data line.
            var path = Path()
            for (i, v) in trend.values.enumerated() {
                let p = CGPoint(x: xFor(i), y: yFor(v))
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            context.stroke(path, with: .color(color), lineWidth: 1.6)
            for (i, v) in trend.values.enumerated() {
                let p = CGPoint(x: xFor(i), y: yFor(v))
                let dot = Path(ellipseIn: CGRect(x: p.x - 2.5, y: p.y - 2.5,
                                                 width: 5, height: 5))
                context.fill(dot, with: .color(color))
            }
        }
    }

    private func flipTier(_ t: ScoreTier) -> ScoreTier {
        switch t {
        case .strong: return .weak
        case .weak:   return .strong
        default:      return t
        }
    }
}

extension ScoreTier {
    var colour: Color {
        switch self {
        case .strong: return TallyTheme.statusGood
        case .mixed:  return TallyTheme.statusCaution
        case .weak:   return TallyTheme.statusBad
        case .na:     return TallyTheme.muted
        }
    }
}

private extension Array {
    subscript(safe idx: Int) -> Element? {
        indices.contains(idx) ? self[idx] : nil
    }
}
