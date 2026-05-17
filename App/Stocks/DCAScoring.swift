import Foundation
import SwiftUI

/// Warren Buffett's "Durable Competitive Advantage" framework, six axes,
/// each scored 0–10. Sources:
///   - Mary Buffett & David Clark, *Warren Buffett and the Interpretation
///     of Financial Statements*
///   - Buffett's annual letters re: ROE / treasury stock / debt
///
/// The scoring rules live in `DCAScorer.score(_:)`. The numeric inputs come
/// out of `FMPParsed` — five years of statements parsed from FMP's JSON.

// MARK: - Parsed inputs

/// Five-to-ten-year slice of statements, in *descending* year order
/// (most recent first). Keep raw numbers; the scorer does the maths.
struct FMPParsed {
    let symbol: String
    let companyName: String
    let years: [Year]
    // Hero-badge inputs. All optional because they're sourced from
    // best-effort endpoints (quote / historical / sector P/E) that can
    // fail without killing the rest of the analysis.
    let currentPrice: Double?
    let priceCurrency: String?
    let oneMonthChangePct: Double?
    let peRatio: Double?
    let sector: String?
    let exchangeShortName: String?
    let sectorPE: Double?
    let isin: String?
    let cusip: String?

    /// Most-recent statement, used for snapshot-style metrics.
    var latest: Year? { years.first }
    /// Oldest statement available — defines the rolling window.
    var oldest: Year? { years.last }

    struct Year {
        let fiscalYear: Int
        // Income
        let revenue: Double
        let grossProfit: Double
        let sga: Double
        let rd: Double
        let depreciation: Double
        let interestExpense: Double
        let netIncome: Double
        let eps: Double
        let weightedShares: Double
        // Balance
        let totalAssets: Double
        let totalLiabilities: Double
        let totalEquity: Double           // common stockholders' equity
        let treasuryStock: Double         // stored as negative; we add it back
        let longTermDebt: Double
        let retainedEarnings: Double
        // Cash flow
        let capex: Double                 // negative in the JSON; we abs() it
        let commonStockRepurchased: Double
    }
}

// MARK: - Parser

/// Decodes the FMP JSON blobs FMPClient hands us into a single `FMPParsed`
/// indexed by fiscal year. Drops any year where one of the three statements
/// is missing — alignment matters for the trend logic.
enum FMPParser {
    private struct IncomeRow: Decodable {
        let fiscalYear: String?
        let date: String
        let revenue: Double?
        let grossProfit: Double?
        let sellingGeneralAndAdministrativeExpenses: Double?
        let researchAndDevelopmentExpenses: Double?
        let depreciationAndAmortization: Double?
        let interestExpense: Double?
        let netIncome: Double?
        let eps: Double?
        let weightedAverageShsOut: Double?
    }
    private struct BalanceRow: Decodable {
        let fiscalYear: String?
        let date: String
        let totalAssets: Double?
        let totalLiabilities: Double?
        let totalStockholdersEquity: Double?
        let treasuryStock: Double?
        let longTermDebt: Double?
        let retainedEarnings: Double?
    }
    private struct CashFlowRow: Decodable {
        let fiscalYear: String?
        let date: String
        let capitalExpenditure: Double?
        let commonStockRepurchased: Double?
    }
    private struct ProfileRow: Decodable {
        let companyName: String?
        let sector: String?
        let exchangeShortName: String?
        let currency: String?
        let isin: String?
        let cusip: String?
    }
    private struct KeyMetricsRow: Decodable {
        let peRatio: Double?
    }
    private struct QuoteRow: Decodable {
        let symbol: String?
        let price: Double?
        let change: Double?
    }
    /// FMP's `historical-price-eod/light` returns either a bare array of
    /// `{date, price}` rows (newer) or an object with `historical: [...]`
    /// (older). Both shapes are tried.
    private struct HistoricalLight: Decodable {
        let historical: [PriceRow]?
        struct PriceRow: Decodable {
            let date: String
            let price: Double?
            let close: Double?
            var bestClose: Double? { close ?? price }
        }
    }
    private struct SectorPERow: Decodable {
        let sector: String?
        let exchange: String?
        let pe: Double?
    }

    static func parse(symbol: String, bundle: FMPClient.AnalysisBundle) throws -> FMPParsed {
        let decoder = JSONDecoder()
        let income   = try decoder.decode([IncomeRow].self,   from: bundle.income.json)
        let balance  = try decoder.decode([BalanceRow].self,  from: bundle.balance.json)
        let cashflow = try decoder.decode([CashFlowRow].self, from: bundle.cashFlow.json)
        let profiles = try decoder.decode([ProfileRow].self,  from: bundle.profile.json)
        // Key-metrics, quote, historical and sector PE are best-effort.
        // Decode failures fall back to `nil` rather than throwing —
        // hero badges hide themselves when their data is missing.
        let keyMetrics: [KeyMetricsRow] = (try? decoder.decode([KeyMetricsRow].self,
                                                               from: bundle.keyMetrics.json)) ?? []
        let quoteRows: [QuoteRow] = bundle.quote.flatMap {
            try? decoder.decode([QuoteRow].self, from: $0.json)
        } ?? []
        let historicalRows: [HistoricalLight.PriceRow] = {
            guard let data = bundle.historical1M?.json else { return [] }
            if let wrapped = try? decoder.decode(HistoricalLight.self, from: data),
               let rows = wrapped.historical {
                return rows
            }
            if let flat = try? decoder.decode([HistoricalLight.PriceRow].self, from: data) {
                return flat
            }
            return []
        }()
        let sectorPERows: [SectorPERow] = bundle.sectorPE.flatMap {
            try? decoder.decode([SectorPERow].self, from: $0.json)
        } ?? []

        // Index by fiscal year so we can align across statements.
        func year(_ s: String?, fallbackDate: String) -> Int {
            if let s, let n = Int(s) { return n }
            return Int(fallbackDate.prefix(4)) ?? 0
        }
        var incomeByYear = [Int: IncomeRow]()
        for r in income  { incomeByYear[year(r.fiscalYear, fallbackDate: r.date)] = r }
        var balanceByYear = [Int: BalanceRow]()
        for r in balance { balanceByYear[year(r.fiscalYear, fallbackDate: r.date)] = r }
        var cashByYear = [Int: CashFlowRow]()
        for r in cashflow { cashByYear[year(r.fiscalYear, fallbackDate: r.date)] = r }

        let years = Set(incomeByYear.keys)
            .intersection(balanceByYear.keys)
            .intersection(cashByYear.keys)
            .sorted(by: >)

        let rows: [FMPParsed.Year] = years.compactMap { y in
            guard let i = incomeByYear[y],
                  let b = balanceByYear[y],
                  let c = cashByYear[y] else { return nil }
            return FMPParsed.Year(
                fiscalYear: y,
                revenue:           i.revenue ?? 0,
                grossProfit:       i.grossProfit ?? 0,
                sga:               i.sellingGeneralAndAdministrativeExpenses ?? 0,
                rd:                i.researchAndDevelopmentExpenses ?? 0,
                depreciation:      i.depreciationAndAmortization ?? 0,
                interestExpense:   i.interestExpense ?? 0,
                netIncome:         i.netIncome ?? 0,
                eps:               i.eps ?? 0,
                weightedShares:    i.weightedAverageShsOut ?? 0,
                totalAssets:       b.totalAssets ?? 0,
                totalLiabilities:  b.totalLiabilities ?? 0,
                totalEquity:       b.totalStockholdersEquity ?? 0,
                treasuryStock:     b.treasuryStock ?? 0,
                longTermDebt:      b.longTermDebt ?? 0,
                retainedEarnings:  b.retainedEarnings ?? 0,
                capex:             abs(c.capitalExpenditure ?? 0),
                commonStockRepurchased: c.commonStockRepurchased ?? 0
            )
        }

        guard !rows.isEmpty else {
            throw FMPClient.FMPError.decoding("No aligned statement years for \(symbol).")
        }

        let profile = profiles.first
        let name = profile?.companyName ?? symbol
        let sector = profile?.sector
        let exchange = profile?.exchangeShortName

        let currentPrice = quoteRows.first?.price

        // Sort by date ascending — FMP's order isn't consistent.
        let pricesByDate: [(String, Double)] = historicalRows.compactMap {
            guard let c = $0.bestClose else { return nil }
            return ($0.date, c)
        }.sorted { $0.0 < $1.0 }
        let changePct: Double? = {
            guard let first = pricesByDate.first?.1,
                  let last  = pricesByDate.last?.1,
                  first > 0 else { return nil }
            return (last - first) / first
        }()

        let peRatio = keyMetrics.first?.peRatio

        let sectorPE: Double? = {
            guard let s = sector else { return nil }
            return sectorPERows.first { row in
                row.sector?.compare(s, options: .caseInsensitive) == .orderedSame
            }?.pe
        }()

        return FMPParsed(
            symbol: symbol,
            companyName: name,
            years: rows,
            currentPrice: currentPrice,
            priceCurrency: profile?.currency,
            oneMonthChangePct: changePct,
            peRatio: peRatio,
            sector: sector,
            exchangeShortName: exchange,
            sectorPE: sectorPE,
            isin: profile?.isin,
            cusip: profile?.cusip
        )
    }
}

// MARK: - Scoring

struct AxisScore: Identifiable {
    let axis: Axis
    /// 0–10 score, or nil if the axis is not applicable (e.g. unprofitable
    /// company → Earnings Quality and Capital Efficiency get skipped).
    let score: Double?
    let headline: String
    let rationale: String
    /// Per-year time series of the underlying metric the axis chiefly
    /// keys on (e.g. gross-profit margin for Pricing Power). Used to
    /// render the inline sparkline + trend chip. nil for unscored axes.
    let trend: AxisTrend?
    /// Threshold lines drawn behind the drill-down chart, so the user
    /// can see at a glance which tier each year lands in. Ordered from
    /// the highest cutoff (strong) to the lowest (weak).
    let thresholds: [AxisThreshold]
    /// Per-component score breakdown lines for composite axes. nil for
    /// single-metric axes, where the rationale prose already explains
    /// the score.
    let breakdown: [String]?
    /// Additional same-units lines plotted on the primary drill-down
    /// chart. Used for composite axes where every input shares the
    /// metric's unit (Cost Discipline: SG&A%, R&D%, Dep% are all
    /// "% of gross profit"). Years and Y-axis scale come from the
    /// primary trend. nil for simple axes and for composites with
    /// mixed units (those use `extraCharts` instead).
    let extraLines: [AxisLine]?
    /// Additional stacked sub-charts below the primary, for composite
    /// axes whose inputs are in different units (Balance Sheet:
    /// D/E ratio plus years-to-pay-down LT debt). Each sub-chart has
    /// its own series, thresholds, and Y-axis.
    let extraCharts: [AxisChart]?
    var id: Axis { axis }
}

/// One additional metric line on a multi-line drill-down chart.
/// The line shares X-years and Y-units with the primary trend.
struct AxisLine: Identifiable {
    let label: String           // "R&D" or "Depreciation"
    let values: [Double]         // chronological, oldest first
    let color: Color
    /// Optional per-metric target (Buffett's own cutoff for THIS line).
    /// Drawn as a thin dashed horizontal in the line's color so the
    /// reader sees each line's own benchmark, not just the primary's.
    let target: Double?
    var id: String { label }
}

/// A complete additional drill-down chart stacked below the primary.
/// Used when a composite axis combines metrics with different units.
struct AxisChart: Identifiable {
    let label: String
    let trend: AxisTrend
    let thresholds: [AxisThreshold]
    var id: String { label }
}

/// One horizontal cutoff drawn on the drill-down chart. The space
/// between two adjacent thresholds is tinted with the tier of the
/// region's upper boundary (for `betterIsHigher` metrics) or the
/// lower (for `betterIsLower` metrics like D/E or SG&A%).
struct AxisThreshold {
    let value: Double
    let tier: ScoreTier
    let label: String
}

/// Five-year metric trend for one axis. Values are chronological,
/// oldest first, so a left-to-right sparkline reads as "past → present".
struct AxisTrend {
    let values: [Double]
    let years: [Int]
    /// For the trend chip: which direction the user actually wants the
    /// metric to move. GPM up = good (true). D/E up = bad (false).
    let betterIsHigher: Bool
    /// Per-value formatter for hover / right-edge label, e.g. "61.6%".
    let format: (Double) -> String

    enum Direction { case improving, stable, deteriorating }

    /// Slope sign over the window, mapped to "is the user happy about
    /// that direction?". Threshold ±5 % relative change so single-year
    /// wobbles don't flip the chip.
    var direction: Direction {
        guard let first = values.first, let last = values.last,
              values.count >= 2, first != 0 else { return .stable }
        let pct = (last - first) / abs(first)
        let signed = betterIsHigher ? pct : -pct
        if signed > 0.05  { return .improving }
        if signed < -0.05 { return .deteriorating }
        return .stable
    }
}

enum ScoreTier { case strong, mixed, weak, na

    static func tier(for score: Double?) -> ScoreTier {
        guard let s = score else { return .na }
        if s >= 8 { return .strong }
        if s >= 5 { return .mixed }
        return .weak
    }
}

enum Axis: String, CaseIterable {
    case pricingPower       = "Pricing Power"
    case costDiscipline     = "Cost Discipline"
    case earningsQuality    = "Earnings Quality"
    case capitalEfficiency  = "Capital Efficiency"
    case balanceSheet       = "Balance Sheet Safety"
    case capitalAllocation  = "Capital Allocation"

    /// Short label for the radar chart corner.
    var short: String {
        switch self {
        case .pricingPower:      return "Pricing"
        case .costDiscipline:    return "Costs"
        case .earningsQuality:   return "Earnings"
        case .capitalEfficiency: return "ROE"
        case .balanceSheet:      return "Balance"
        case .capitalAllocation: return "Capital"
        }
    }
}

/// Fair-value verdict derived from the stock's trailing P/E vs the
/// average P/E of its sector on the same exchange. Wide ±15% bands so
/// quarterly EPS wobbles don't flip the chip — sector P/E is coarse.
enum FairValue {
    case underpriced, fair, overpriced, unknown
}

struct DCAScorecard {
    let symbol: String
    let companyName: String
    let analysedAt: Date
    let windowDescription: String        // "financials FY2020–FY2024"
    let axes: [AxisScore]
    let shape: String                    // one-line interpretation
    let fromCache: Bool
    let stale: Bool
    let cacheAgeDays: Int
    // Hero-badge inputs — surfaced as chips next to the symbol/score.
    let currentPrice: Double?
    let priceCurrency: String?
    let oneMonthChangePct: Double?
    let peRatio: Double?
    let sector: String?
    let sectorPE: Double?
    let isin: String?
    let cusip: String?

    /// Sum of applicable axes; max is `applicableAxes * 10`.
    var totalScore: Double { axes.compactMap { $0.score }.reduce(0, +) }
    var maxScore: Int { axes.filter { $0.score != nil }.count * 10 }

    /// Fair-value bucket derived from `peRatio / sectorPE`. Returns
    /// `.unknown` whenever either input is missing or non-positive.
    var fairValueVerdict: FairValue {
        guard let pe = peRatio, pe > 0,
              let sp = sectorPE, sp > 0 else { return .unknown }
        let ratio = pe / sp
        if ratio < 0.85 { return .underpriced }
        if ratio > 1.15 { return .overpriced }
        return .fair
    }

    /// German securities identifier (Wertpapierkennnummer). For ISINs
    /// starting with `DE` the WKN is embedded as the first 6 chars of
    /// the local identifier by Deutsche Börse convention. For non-DE
    /// ISINs the WKN is not algorithmically derivable — returns nil.
    var wkn: String? {
        guard let isin = isin, isin.hasPrefix("DE"), isin.count == 12 else {
            return nil
        }
        let nsid = isin.dropFirst(2).dropLast(1)   // 9-char national identifier
        return String(nsid.prefix(6))
    }
}

enum DCAScorer {

    static func score(_ p: FMPParsed,
                      bundle: FMPClient.AnalysisBundle,
                      analysedAt: Date = Date()) -> DCAScorecard {
        let yearsUsed = p.years
        // Most-recent slice we'll quote in headlines.
        let latest = yearsUsed.first!

        // Are we in a loss-making window? Determines whether the earnings-
        // dependent axes are scored or skipped.
        let unprofitable = yearsUsed.allSatisfy { $0.netIncome <= 0 }

        var axes: [AxisScore] = []
        axes.append(pricingPower(yearsUsed, latest: latest))
        axes.append(costDiscipline(yearsUsed, latest: latest))
        axes.append(earningsQuality(yearsUsed, latest: latest, unprofitable: unprofitable))
        axes.append(capitalEfficiency(yearsUsed, latest: latest, unprofitable: unprofitable))
        axes.append(balanceSheetSafety(yearsUsed, latest: latest))
        axes.append(capitalAllocation(yearsUsed, latest: latest))

        let windowDescription: String = {
            let last = yearsUsed.first!.fiscalYear
            let first = yearsUsed.last!.fiscalYear
            return "financials FY\(first)–FY\(last)"
        }()

        let shape = interpretation(for: axes)

        return DCAScorecard(
            symbol: p.symbol,
            companyName: p.companyName,
            analysedAt: analysedAt,
            windowDescription: windowDescription,
            axes: axes,
            shape: shape,
            fromCache: bundle.fullyCached,
            stale: bundle.stale,
            cacheAgeDays: max(0, Int(analysedAt.timeIntervalSince(bundle.oldestFetch) / 86400)),
            currentPrice: p.currentPrice,
            priceCurrency: p.priceCurrency,
            oneMonthChangePct: p.oneMonthChangePct,
            peRatio: p.peRatio,
            sector: p.sector,
            sectorPE: p.sectorPE,
            isin: p.isin,
            cusip: p.cusip
        )
    }

    // MARK: - Axis 1 — Pricing Power

    private static func pricingPower(_ years: [FMPParsed.Year], latest: FMPParsed.Year) -> AxisScore {
        let gpms = years.map { safeDiv($0.grossProfit, $0.revenue) }
        let avg = mean(gpms) ?? 0
        let now = gpms.first ?? 0

        let score: Double
        switch now {
        case 0.60...:     score = 10
        case 0.40..<0.60: score = 7 + (now - 0.40) / 0.20 * 2     // 7..9
        case 0.20..<0.40: score = 3 + (now - 0.20) / 0.20 * 3     // 3..6
        default:          score = max(0, now / 0.20 * 2)          // 0..2
        }
        let scoreClamped = min(10, max(0, score))

        let headline = String(format: "GPM %.1f%% (window avg %.1f%%)", now * 100, avg * 100)
        var rationale = "Gross-profit margin is the cleanest read on pricing power: how much of every dollar of sales survives the cost of goods. "
        if now >= 0.40 {
            rationale += "Above 40% over a multi-year stretch is the Buffett threshold for a moat. "
        } else if now >= 0.20 {
            rationale += "Between 20–40% — competitive market, no obvious moat. "
        } else {
            rationale += "Below 20% — commodity-like economics, hard to defend against cheaper rivals. "
        }
        if years.count < 7 {
            rationale += "Based on a \(years.count)-year window; Buffett's 10-year rule cannot be fully applied on the FMP free tier."
        }
        let trend = AxisTrend(
            values: gpms.reversed(),
            years: years.map(\.fiscalYear).reversed(),
            betterIsHigher: true,
            format: { String(format: "%.1f%%", $0 * 100) }
        )
        let thresholds: [AxisThreshold] = [
            AxisThreshold(value: 0.60, tier: .strong, label: "60% — strong moat"),
            AxisThreshold(value: 0.40, tier: .mixed,  label: "40% — Buffett floor"),
            AxisThreshold(value: 0.20, tier: .weak,   label: "20% — commodity"),
        ]
        return AxisScore(
            axis: .pricingPower, score: scoreClamped,
            headline: headline, rationale: rationale,
            trend: trend, thresholds: thresholds, breakdown: nil,
            extraLines: nil, extraCharts: nil
        )
    }

    // MARK: - Axis 2 — Cost Discipline (composite)

    private static func costDiscipline(_ years: [FMPParsed.Year], latest: FMPParsed.Year) -> AxisScore {
        let sgaRatio = safeDiv(latest.sga, latest.grossProfit)
        let rdRatio  = safeDiv(latest.rd, latest.grossProfit)
        let depRatio = safeDiv(latest.depreciation, latest.grossProfit)

        var score = 0.0
        // SG&A — 4 points
        let sgaPoints: Double
        if sgaRatio <= 0.30 { sgaPoints = 4 }
        else if sgaRatio <= 0.50 { sgaPoints = 2.5 }
        else if sgaRatio <= 0.80 { sgaPoints = 1 }
        else { sgaPoints = 0 }
        score += sgaPoints
        // R&D — 3 points, where minimal R&D is rewarded (Buffett's "moat
        // that doesn't need defending" point) but heavy R&D isn't punished
        // below zero — it's an information signal more than a verdict.
        let rdPoints: Double
        if rdRatio <= 0.05 { rdPoints = 3 }
        else if rdRatio <= 0.15 { rdPoints = 2 }
        else if rdRatio <= 0.30 { rdPoints = 1 }
        else { rdPoints = 0 }
        score += rdPoints
        // Depreciation — 3 points
        let depPoints: Double
        if depRatio <= 0.10 { depPoints = 3 }
        else if depRatio <= 0.20 { depPoints = 2 }
        else if depRatio <= 0.40 { depPoints = 1 }
        else { depPoints = 0 }
        score += depPoints

        // Any single component > 80% → cap at 3 regardless.
        if sgaRatio > 0.80 || depRatio > 0.80 {
            score = min(score, 3)
        }
        let final = min(10, max(0, score))

        let headline = String(format: "SG&A %.0f%% · R&D %.0f%% · Dep %.0f%%",
                              sgaRatio * 100, rdRatio * 100, depRatio * 100)
        var rationale = ""
        if sgaRatio <= 0.30 { rationale += "SG&A under 30% of gross profit — durable cost discipline. " }
        else if sgaRatio > 0.80 { rationale += "SG&A burning through over 80% of gross profit — operating margin is thin. " }
        if rdRatio > 0.15 {
            rationale += "Heavy R&D (\(Int(rdRatio*100))% of gross profit) is a flag — moats that need constant R&D defence (pharma, semis) face perpetual reinvention risk. "
        }
        if depRatio > 0.20 {
            rationale += "Depreciation is a real and recurring cost — Buffett rejects EBITDA-based reasoning. "
        }
        // Trend metric: SG&A as % of gross profit per year — the largest
        // and most variable of the three composite inputs, so it carries
        // the most information when shown as a sparkline.
        let sgaSeries = years.map { safeDiv($0.sga, $0.grossProfit) }
        let trend = AxisTrend(
            values: sgaSeries.reversed(),
            years: years.map(\.fiscalYear).reversed(),
            betterIsHigher: false,
            format: { String(format: "%.0f%%", $0 * 100) }
        )
        let thresholds: [AxisThreshold] = [
            AxisThreshold(value: 0.30, tier: .strong, label: "≤30% SG&A — Buffett target"),
            AxisThreshold(value: 0.50, tier: .mixed,  label: "≤50%"),
            AxisThreshold(value: 0.80, tier: .weak,   label: "80% cap"),
        ]
        let breakdown: [String] = [
            String(format: "SG&A %.0f%%  →  %@/4", sgaRatio * 100, formatPts(sgaPoints)),
            String(format: "R&D  %.0f%%  →  %@/3", rdRatio * 100, formatPts(rdPoints)),
            String(format: "Dep  %.0f%%  →  %@/3", depRatio * 100, formatPts(depPoints)),
            String(format: "Total  →  %@/10", formatPts(final)),
        ]
        // The honest version of the chart: all three composite inputs
        // on the same axis, so the user sees which of them is driving
        // the score — not just SG&A (the headline) while R&D quietly
        // tanks the verdict (AMZN's failure mode).
        let rdSeries  = years.map { safeDiv($0.rd, $0.grossProfit) }.reversed()
        let depSeries = years.map { safeDiv($0.depreciation, $0.grossProfit) }.reversed()
        let extraLines: [AxisLine] = [
            AxisLine(label: "R&D",
                     values: Array(rdSeries),
                     color: TallyTheme.chartLine2,
                     target: 0.05),
            AxisLine(label: "Dep",
                     values: Array(depSeries),
                     color: TallyTheme.chartLine3,
                     target: 0.10),
        ]
        return AxisScore(
            axis: .costDiscipline, score: final,
            headline: headline, rationale: rationale,
            trend: trend, thresholds: thresholds, breakdown: breakdown,
            extraLines: extraLines, extraCharts: nil
        )
    }

    // MARK: - Axis 3 — Earnings Quality

    private static func earningsQuality(_ years: [FMPParsed.Year], latest: FMPParsed.Year, unprofitable: Bool) -> AxisScore {
        if unprofitable {
            return AxisScore(axis: .earningsQuality, score: nil,
                             headline: "N/A — unprofitable in window",
                             rationale: "Net income was zero or negative across the available years; earnings-quality scoring is skipped.",
                             trend: nil, thresholds: [], breakdown: nil,
                             extraLines: nil, extraCharts: nil)
        }
        let netMargin = safeDiv(latest.netIncome, latest.revenue)
        let epsTrend = trendQuality(values: years.map(\.eps).reversed().map { $0 })
        // 0–7 from margin, 0–3 from trend smoothness
        let marginScore: Double = {
            switch netMargin {
            case 0.20...:     return 7
            case 0.10..<0.20: return 4 + (netMargin - 0.10) / 0.10 * 3
            default:          return max(0, netMargin / 0.10 * 4)
            }
        }()
        let total = min(10, max(0, marginScore + epsTrend.bonus))

        let headline = String(format: "Net margin %.1f%%, EPS %@",
                              netMargin * 100, epsTrend.label)
        var rationale = "Buffett's earnings-quality test is twofold: net margin above 20% over the cycle, and an EPS line that climbs without dramatic dips. "
        if netMargin >= 0.20 {
            rationale += "Net margin above 20% — strong, suggests pricing power flows through to the bottom line. "
        } else if netMargin >= 0.10 {
            rationale += "Net margin 10–20% — decent, not exceptional. "
        } else {
            rationale += "Net margin below 10% — thin, easily eroded by input-cost shocks. "
        }
        rationale += epsTrend.commentary
        let netSeries = years.map { safeDiv($0.netIncome, $0.revenue) }
        let trend = AxisTrend(
            values: netSeries.reversed(),
            years: years.map(\.fiscalYear).reversed(),
            betterIsHigher: true,
            format: { String(format: "%.1f%%", $0 * 100) }
        )
        let thresholds: [AxisThreshold] = [
            AxisThreshold(value: 0.20, tier: .strong, label: "20% — strong"),
            AxisThreshold(value: 0.10, tier: .mixed,  label: "10% — adequate"),
        ]
        let breakdown: [String] = [
            String(format: "Net margin %.1f%%  →  %@/7", netMargin * 100, formatPts(marginScore)),
            "EPS trend \(epsTrend.label)  →  \(formatPts(epsTrend.bonus))/3",
            String(format: "Total  →  %@/10", formatPts(total)),
        ]
        return AxisScore(
            axis: .earningsQuality, score: total,
            headline: headline, rationale: rationale,
            trend: trend, thresholds: thresholds, breakdown: breakdown,
            extraLines: nil, extraCharts: nil
        )
    }

    // MARK: - Axis 4 — Capital Efficiency (adjusted ROE)

    private static func capitalEfficiency(_ years: [FMPParsed.Year], latest: FMPParsed.Year, unprofitable: Bool) -> AxisScore {
        if unprofitable {
            return AxisScore(axis: .capitalEfficiency, score: nil,
                             headline: "N/A — unprofitable in window",
                             rationale: "ROE is meaningless when earnings are zero or negative; capital-efficiency scoring is skipped.",
                             trend: nil, thresholds: [], breakdown: nil,
                             extraLines: nil, extraCharts: nil)
        }
        // Adjusted equity = equity + |treasury stock|. Buffett's rule:
        // share buybacks don't make a company *less* capital-efficient.
        let adjEquity = latest.totalEquity + abs(latest.treasuryStock)
        if adjEquity <= 0 {
            return AxisScore(axis: .capitalEfficiency, score: nil,
                             headline: "N/A — negative or zero adjusted equity",
                             rationale: "Adjusted shareholders' equity is non-positive — likely heavy buybacks beyond cumulative retained earnings. Scoring uses the other axes only.",
                             trend: nil, thresholds: [], breakdown: nil,
                             extraLines: nil, extraCharts: nil)
        }
        let adjROE = latest.netIncome / adjEquity
        let dToE = safeDiv(latest.totalLiabilities, adjEquity)
        let roa = safeDiv(latest.netIncome, latest.totalAssets)

        var score: Double
        switch adjROE {
        case 0.30...:     score = 10
        case 0.20..<0.30: score = 7 + (adjROE - 0.20) / 0.10 * 2
        case 0.15..<0.20: score = 5 + (adjROE - 0.15) / 0.05 * 1
        default:          score = max(0, adjROE / 0.15 * 4)
        }
        var rationale = "Adjusted ROE = Net Income ÷ (Equity + Treasury Stock). Adding back treasury stock undoes the inflation that share buybacks create in headline ROE. "
        // Leverage penalty: high ROE driven by debt is a finance trick, not a moat.
        if dToE > 0.80 && adjROE > 0.20 {
            score = min(score, 5)
            rationale += "Debt-to-equity of \(String(format: "%.2f", dToE)) above 0.80 with ROE >20% — much of the headline return is borrowed, capped at 5/10. "
        }
        // Very high ROA flag: low capital barrier to entry is itself a vulnerability.
        if roa > 0.30 && adjROE < roa * 1.5 {
            rationale += "ROA of \(String(format: "%.0f%%", roa*100)) is unusually high — Buffett notes this can signal an *easy-to-copy* business with low capital intensity, paradoxically a weaker moat. "
        }
        let final = min(10, max(0, score))
        let headline = String(format: "Adj ROE %.1f%%", adjROE * 100)
        // Per-year adjusted ROE trend.
        let roeSeries: [Double] = years.map { y in
            let eq = y.totalEquity + abs(y.treasuryStock)
            return eq > 0 ? y.netIncome / eq : 0
        }
        let trend = AxisTrend(
            values: roeSeries.reversed(),
            years: years.map(\.fiscalYear).reversed(),
            betterIsHigher: true,
            format: { String(format: "%.1f%%", $0 * 100) }
        )
        let thresholds: [AxisThreshold] = [
            AxisThreshold(value: 0.30, tier: .strong, label: "30% — top quality"),
            AxisThreshold(value: 0.20, tier: .mixed,  label: "20% — Buffett floor"),
            AxisThreshold(value: 0.15, tier: .weak,   label: "15% — soft"),
        ]
        return AxisScore(
            axis: .capitalEfficiency, score: final,
            headline: headline, rationale: rationale,
            trend: trend, thresholds: thresholds, breakdown: nil,
            extraLines: nil, extraCharts: nil
        )
    }

    // MARK: - Axis 5 — Balance Sheet Safety (composite)

    private static func balanceSheetSafety(_ years: [FMPParsed.Year], latest: FMPParsed.Year) -> AxisScore {
        let adjEquity = latest.totalEquity + abs(latest.treasuryStock)
        let dToE = adjEquity > 0 ? latest.totalLiabilities / adjEquity : Double.infinity

        // Years to pay down long-term debt out of one year of net earnings.
        // Use the average of the last three years' earnings to smooth a single
        // bad year — same spirit as Buffett's "look at the trend" rule.
        let avgNet = mean(years.prefix(3).map(\.netIncome)) ?? latest.netIncome
        let payDownYears: Double
        if avgNet > 0 && latest.longTermDebt > 0 {
            payDownYears = latest.longTermDebt / avgNet
        } else if latest.longTermDebt <= 0 {
            payDownYears = 0
        } else {
            payDownYears = .infinity
        }

        var score: Double = 0
        // Debt / equity component — 5 pts.
        let dePts: Double
        if dToE < 0.30 { dePts = 5 }
        else if dToE < 0.80 { dePts = 4 }
        else if dToE < 1.20 { dePts = 2 }
        else { dePts = 0 }
        score += dePts
        // Pay-down-LT-debt component — 5 pts.
        let payPts: Double
        if payDownYears <= 3 { payPts = 5 }
        else if payDownYears <= 4 { payPts = 4 }
        else if payDownYears <= 6 { payPts = 2 }
        else { payPts = 0 }
        score += payPts
        let final = min(10, max(0, score))

        var headline: String
        if payDownYears.isFinite {
            headline = String(format: "D/E %.2f · LT debt %.1f yr",
                              dToE.isFinite ? dToE : 0, payDownYears)
        } else {
            headline = String(format: "D/E %.2f · LT debt: no earnings cover",
                              dToE.isFinite ? dToE : 0)
        }
        var rationale = "Adjusted debt-to-equity uses (equity + treasury stock) as the denominator — same correction as the ROE axis. Buffett's rule: durable-moat companies pay long-term debt off in 3–4 years of earnings. "
        rationale += "Note: the *current ratio* is not used here. Many DCA companies have current ratios under 1 because earning power covers liabilities — penalising that would mis-fire."
        // Trend metric: D/E across the window. Lower is better.
        let deSeries: [Double] = years.map { y in
            let eq = y.totalEquity + abs(y.treasuryStock)
            return eq > 0 ? y.totalLiabilities / eq : 0
        }
        let trend = AxisTrend(
            values: deSeries.reversed(),
            years: years.map(\.fiscalYear).reversed(),
            betterIsHigher: false,
            format: { String(format: "%.2f", $0) }
        )
        let thresholds: [AxisThreshold] = [
            AxisThreshold(value: 0.30, tier: .strong, label: "D/E ≤ 0.30 — strong"),
            AxisThreshold(value: 0.80, tier: .mixed,  label: "D/E ≤ 0.80 — Buffett target"),
            AxisThreshold(value: 1.20, tier: .weak,   label: "D/E ≤ 1.20"),
        ]
        let payText: String
        if payDownYears.isFinite {
            payText = String(format: "%.1f yr", payDownYears)
        } else {
            payText = "no earnings cover"
        }
        let breakdown: [String] = [
            String(format: "D/E %.2f  →  %@/5", dToE.isFinite ? dToE : 0, formatPts(dePts)),
            "LT-debt pay-down \(payText)  →  \(formatPts(payPts))/5",
            String(format: "Total  →  %@/10", formatPts(final)),
        ]
        // Years-to-pay-down LT debt — second composite input. Mixed
        // units with D/E, so it goes in its own stacked sub-chart
        // rather than as a line on the primary D/E chart. We compute
        // the per-year ratio with that year's own net income (or a
        // 3-year smoothed denominator when net is volatile).
        let payDownSeries: [Double] = years.map { y in
            // Smooth the denominator with the 3-most-recent-year average
            // to avoid a single bad year producing a spike that doesn't
            // reflect a real change in leverage cover.
            let net3 = mean(years.prefix(3).map(\.netIncome)) ?? y.netIncome
            guard y.longTermDebt > 0, net3 > 0 else { return 0 }
            return y.longTermDebt / net3
        }
        let payDownTrend = AxisTrend(
            values: payDownSeries.reversed(),
            years: years.map(\.fiscalYear).reversed(),
            betterIsHigher: false,
            format: { String(format: "%.1f yr", $0) }
        )
        let payDownThresholds: [AxisThreshold] = [
            AxisThreshold(value: 3, tier: .strong, label: "≤3 yr — Buffett target"),
            AxisThreshold(value: 4, tier: .mixed,  label: "≤4 yr"),
            AxisThreshold(value: 6, tier: .weak,   label: "≤6 yr"),
        ]
        let extraCharts: [AxisChart] = [
            AxisChart(label: "Years to pay down LT debt",
                      trend: payDownTrend,
                      thresholds: payDownThresholds),
        ]
        return AxisScore(
            axis: .balanceSheet, score: final,
            headline: headline, rationale: rationale,
            trend: trend, thresholds: thresholds, breakdown: breakdown,
            extraLines: nil, extraCharts: extraCharts
        )
    }

    // MARK: - Axis 6 — Capital Allocation (composite)

    private static func capitalAllocation(_ years: [FMPParsed.Year], latest: FMPParsed.Year) -> AxisScore {
        let netEarnings = years.map(\.netIncome).filter { $0 > 0 }
        let capexAvg = mean(years.map(\.capex)) ?? 0
        let netAvg   = mean(netEarnings) ?? latest.netIncome
        let capexRatio = safeDiv(capexAvg, netAvg)

        // Buyback consistency: share count trend (lower = good).
        let shares = years.map(\.weightedShares).reversed().map { $0 }
        let buybackTrend = trendDirection(values: shares, lowerIsBetter: true)

        // Retained earnings CAGR — proxy for compounding ability.
        let retEarnings = years.map(\.retainedEarnings).reversed().map { $0 }
        let reCagr = cagr(retEarnings)

        var score = 0.0
        // CapEx / earnings — 4 points
        let capexPts: Double
        if capexRatio < 0.25 { capexPts = 4 }
        else if capexRatio < 0.50 { capexPts = 2 }
        else { capexPts = 0 }
        score += capexPts
        // Buyback consistency — 3 points
        let bbPts: Double
        if buybackTrend == .decreasing { bbPts = 3 }
        else if buybackTrend == .flat { bbPts = 1 }
        else { bbPts = 0 }
        score += bbPts
        // RE CAGR > 8% — 3 points
        let rePts: Double
        if let c = reCagr, c > 0.08 { rePts = 3 }
        else if let c = reCagr, c > 0.04 { rePts = 1.5 }
        else { rePts = 0 }
        score += rePts

        let final = min(10, max(0, score))

        var bbText: String
        switch buybackTrend {
        case .decreasing: bbText = "buybacks consistent"
        case .flat:       bbText = "shares flat"
        case .increasing: bbText = "share count rising"
        }
        var reText = "—"
        if let c = reCagr {
            reText = String(format: "RE CAGR %.1f%%", c * 100)
        }
        let headline = String(format: "CapEx %.0f%% · %@ · %@",
                              capexRatio * 100, bbText, reText)
        var rationale = "Three Buffett tests of capital allocation: (1) CapEx as a fraction of net earnings should stay below 25% (durable moats don't need to be constantly rebuilt); (2) share count should trend down over time (real, ongoing buybacks); (3) retained earnings should compound at a healthy pace. "
        if capexRatio > 0.50 {
            rationale += "CapEx is eating over half of earnings — Buffett's 'maintenance CapEx' warning: a wide moat with thin free cash flow can quietly destroy value. "
        }
        if buybackTrend == .increasing {
            rationale += "Share count is *rising* — dilution, not buybacks. "
        }
        // Trend metric: CapEx as % of net earnings each year. Lower = better.
        let capexSeries: [Double] = years.map { y in
            y.netIncome > 0 ? y.capex / y.netIncome : 0
        }
        let trend = AxisTrend(
            values: capexSeries.reversed(),
            years: years.map(\.fiscalYear).reversed(),
            betterIsHigher: false,
            format: { String(format: "%.0f%%", $0 * 100) }
        )
        let thresholds: [AxisThreshold] = [
            AxisThreshold(value: 0.25, tier: .strong, label: "CapEx ≤ 25%"),
            AxisThreshold(value: 0.50, tier: .mixed,  label: "CapEx ≤ 50%"),
        ]
        let reBreakdownText: String = reCagr.map { String(format: "%.1f%%", $0 * 100) } ?? "n/a"
        let bbBreakdownText: String
        switch buybackTrend {
        case .decreasing: bbBreakdownText = "decreasing"
        case .flat:       bbBreakdownText = "flat"
        case .increasing: bbBreakdownText = "rising"
        }
        let breakdown: [String] = [
            String(format: "CapEx %.0f%%  →  %@/4", capexRatio * 100, formatPts(capexPts)),
            "Share count \(bbBreakdownText)  →  \(formatPts(bbPts))/3",
            "Retained-earnings CAGR \(reBreakdownText)  →  \(formatPts(rePts))/3",
            String(format: "Total  →  %@/10", formatPts(final)),
        ]
        // Share count over time — second composite input. Mixed units
        // with CapEx ratio (absolute count vs %), so stacked sub-chart.
        // Buffett wants this line trending DOWN (real ongoing buybacks).
        // No thresholds — the verdict is shape (slope) rather than
        // crossing a numeric cutoff.
        let shareSeries = years.map(\.weightedShares).reversed()
        let shareTrend = AxisTrend(
            values: Array(shareSeries),
            years: years.map(\.fiscalYear).reversed(),
            betterIsHigher: false,
            format: { v in
                // Big numbers: shares are usually 100M-15B. Render in
                // millions for readability, e.g. "4 309M".
                let millions = v / 1_000_000
                return String(format: "%.0fM", millions)
            }
        )
        let extraCharts: [AxisChart] = [
            AxisChart(label: "Weighted shares outstanding",
                      trend: shareTrend,
                      thresholds: []),
        ]
        return AxisScore(
            axis: .capitalAllocation, score: final,
            headline: headline, rationale: rationale,
            trend: trend, thresholds: thresholds, breakdown: breakdown,
            extraLines: nil, extraCharts: extraCharts
        )
    }

    // MARK: - Shape interpretation

    private static func interpretation(for axes: [AxisScore]) -> String {
        func get(_ a: Axis) -> Double? { axes.first { $0.axis == a }?.score }
        let pricing = get(.pricingPower) ?? 0
        let costs   = get(.costDiscipline) ?? 0
        let earn    = get(.earningsQuality) ?? 0
        let cap     = get(.capitalEfficiency) ?? 0
        let bal     = get(.balanceSheet) ?? 0
        let alloc   = get(.capitalAllocation) ?? 0

        let allHigh = [pricing, costs, earn, cap, bal, alloc].allSatisfy { $0 >= 8 }
        if allHigh {
            return "Classic DCA pattern — strong on every axis (cf. Coca-Cola, Moody's, See's Candy)."
        }
        if pricing >= 8 && cap >= 7 && bal < 5 {
            return "Strong margins and ROE but a weak balance sheet — leveraged DCA, often post-LBO or aggressive-buyback. Investigate whether the leverage is structural or temporary."
        }
        if cap >= 8 && earn < 5 {
            return "High ROE with thin margins — financial engineering risk. Check whether buyback-driven share-count reduction is doing the heavy lifting."
        }
        if pricing >= 8 && costs >= 7 && earn >= 7 && alloc < 5 {
            return "Great business, questionable management — wide moat, but capital is being deployed poorly."
        }
        if pricing >= 8 && cap < 5 {
            return "Wide moat being squandered — high gross margins not translating to capital efficiency. Buffett's maintenance-CapEx warning applies."
        }
        let nApplicable = axes.compactMap { $0.score }.count
        let total = axes.compactMap { $0.score }.reduce(0, +)
        let pct = total / Double(nApplicable * 10)
        switch pct {
        case 0.80...: return "Mostly Buffett-shaped — a few rough edges to investigate."
        case 0.60...: return "Mixed — has DCA traits but doesn't cleanly fit the pattern."
        default:      return "Not a Buffett-style DCA company by the framework's tests."
        }
    }

    // MARK: - Helpers

    /// "2.5" not "2.50000…" and "3" not "3.0" — used in the breakdown
    /// strings so "3/3" reads naturally next to "2.5/4".
    private static func formatPts(_ v: Double) -> String {
        if v.rounded() == v {
            return String(Int(v))
        }
        return String(format: "%.1f", v)
    }

    private static func safeDiv(_ a: Double, _ b: Double) -> Double {
        guard b != 0, b.isFinite else { return 0 }
        return a / b
    }
    private static func mean(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        return xs.reduce(0, +) / Double(xs.count)
    }
    private static func mean(_ xs: ArraySlice<Double>) -> Double? {
        guard !xs.isEmpty else { return nil }
        return xs.reduce(0, +) / Double(xs.count)
    }

    private enum Trend { case decreasing, flat, increasing }
    private static func trendDirection(values: [Double], lowerIsBetter: Bool) -> Trend {
        guard values.count >= 2 else { return .flat }
        let first = values.first ?? 0
        let last  = values.last ?? 0
        guard first > 0 else { return .flat }
        let delta = (last - first) / first
        if delta > 0.03 { return .increasing }
        if delta < -0.03 { return .decreasing }
        return .flat
    }

    private struct TrendQuality {
        let bonus: Double
        let label: String
        let commentary: String
    }
    /// Returns up to +3 if the EPS line climbs smoothly, ~+1 if it climbs
    /// erratically, 0 or worse if it's flat or falling.
    private static func trendQuality(values: [Double]) -> TrendQuality {
        guard values.count >= 2 else {
            return TrendQuality(bonus: 0, label: "trend unavailable",
                                commentary: "EPS history too short to judge trend.")
        }
        let first = values.first ?? 0
        let last  = values.last ?? 0
        let up    = last > first
        // Count year-over-year drops as a smoothness measure.
        var drops = 0
        for i in 1..<values.count where values[i] < values[i-1] {
            drops += 1
        }
        let smooth = drops <= 1
        switch (up, smooth) {
        case (true,  true):
            return TrendQuality(bonus: 3, label: "upward + smooth",
                                commentary: "EPS climbed steadily across the window — a hallmark Buffett pattern. ")
        case (true,  false):
            return TrendQuality(bonus: 1.5, label: "upward but bumpy",
                                commentary: "EPS finished higher than it started but with several dips — the trend is right, the consistency isn't. ")
        case (false, true):
            return TrendQuality(bonus: 0, label: "flat or declining",
                                commentary: "EPS did not grow over the window. ")
        case (false, false):
            return TrendQuality(bonus: 0, label: "erratic and lower",
                                commentary: "EPS bounced and ended below where it started. ")
        }
    }

    private static func cagr(_ values: [Double]) -> Double? {
        guard values.count >= 2 else { return nil }
        let first = values.first ?? 0
        let last  = values.last ?? 0
        guard first > 0, last > 0 else { return nil }
        let n = Double(values.count - 1)
        return pow(last / first, 1.0 / n) - 1.0
    }
}
