import Foundation

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
    }

    static func parse(symbol: String, bundle: FMPClient.AnalysisBundle) throws -> FMPParsed {
        let decoder = JSONDecoder()
        let income   = try decoder.decode([IncomeRow].self,   from: bundle.income.json)
        let balance  = try decoder.decode([BalanceRow].self,  from: bundle.balance.json)
        let cashflow = try decoder.decode([CashFlowRow].self, from: bundle.cashFlow.json)
        let profiles = try decoder.decode([ProfileRow].self,  from: bundle.profile.json)

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

        let name = profiles.first?.companyName ?? symbol
        return FMPParsed(symbol: symbol, companyName: name, years: rows)
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
    var id: Axis { axis }
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

    /// Sum of applicable axes; max is `applicableAxes * 10`.
    var totalScore: Double { axes.compactMap { $0.score }.reduce(0, +) }
    var maxScore: Int { axes.filter { $0.score != nil }.count * 10 }
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
            cacheAgeDays: max(0, Int(analysedAt.timeIntervalSince(bundle.oldestFetch) / 86400))
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
        return AxisScore(axis: .pricingPower, score: scoreClamped,
                         headline: headline, rationale: rationale)
    }

    // MARK: - Axis 2 — Cost Discipline (composite)

    private static func costDiscipline(_ years: [FMPParsed.Year], latest: FMPParsed.Year) -> AxisScore {
        let sgaRatio = safeDiv(latest.sga, latest.grossProfit)
        let rdRatio  = safeDiv(latest.rd, latest.grossProfit)
        let depRatio = safeDiv(latest.depreciation, latest.grossProfit)

        var score = 0.0
        // SG&A — 4 points
        if sgaRatio <= 0.30 { score += 4 }
        else if sgaRatio <= 0.50 { score += 2.5 }
        else if sgaRatio <= 0.80 { score += 1 }
        // R&D — 3 points, where minimal R&D is rewarded (Buffett's "moat
        // that doesn't need defending" point) but heavy R&D isn't punished
        // below zero — it's an information signal more than a verdict.
        if rdRatio <= 0.05 { score += 3 }
        else if rdRatio <= 0.15 { score += 2 }
        else if rdRatio <= 0.30 { score += 1 }
        // Depreciation — 3 points
        if depRatio <= 0.10 { score += 3 }
        else if depRatio <= 0.20 { score += 2 }
        else if depRatio <= 0.40 { score += 1 }

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
        return AxisScore(axis: .costDiscipline, score: final,
                         headline: headline, rationale: rationale)
    }

    // MARK: - Axis 3 — Earnings Quality

    private static func earningsQuality(_ years: [FMPParsed.Year], latest: FMPParsed.Year, unprofitable: Bool) -> AxisScore {
        if unprofitable {
            return AxisScore(axis: .earningsQuality, score: nil,
                             headline: "N/A — unprofitable in window",
                             rationale: "Net income was zero or negative across the available years; earnings-quality scoring is skipped.")
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
        return AxisScore(axis: .earningsQuality, score: total,
                         headline: headline, rationale: rationale)
    }

    // MARK: - Axis 4 — Capital Efficiency (adjusted ROE)

    private static func capitalEfficiency(_ years: [FMPParsed.Year], latest: FMPParsed.Year, unprofitable: Bool) -> AxisScore {
        if unprofitable {
            return AxisScore(axis: .capitalEfficiency, score: nil,
                             headline: "N/A — unprofitable in window",
                             rationale: "ROE is meaningless when earnings are zero or negative; capital-efficiency scoring is skipped.")
        }
        // Adjusted equity = equity + |treasury stock|. Buffett's rule:
        // share buybacks don't make a company *less* capital-efficient.
        let adjEquity = latest.totalEquity + abs(latest.treasuryStock)
        if adjEquity <= 0 {
            return AxisScore(axis: .capitalEfficiency, score: nil,
                             headline: "N/A — negative or zero adjusted equity",
                             rationale: "Adjusted shareholders' equity is non-positive — likely heavy buybacks beyond cumulative retained earnings. Scoring uses the other axes only.")
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
        return AxisScore(axis: .capitalEfficiency, score: final,
                         headline: headline, rationale: rationale)
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
        if dToE < 0.30 { score += 5 }
        else if dToE < 0.80 { score += 4 }
        else if dToE < 1.20 { score += 2 }
        // Pay-down-LT-debt component — 5 pts.
        if payDownYears <= 3 { score += 5 }
        else if payDownYears <= 4 { score += 4 }
        else if payDownYears <= 6 { score += 2 }
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
        return AxisScore(axis: .balanceSheet, score: final,
                         headline: headline, rationale: rationale)
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
        if capexRatio < 0.25 { score += 4 }
        else if capexRatio < 0.50 { score += 2 }
        // Buyback consistency — 3 points
        if buybackTrend == .decreasing { score += 3 }
        else if buybackTrend == .flat { score += 1 }
        // RE CAGR > 8% — 3 points
        if let c = reCagr, c > 0.08 { score += 3 }
        else if let c = reCagr, c > 0.04 { score += 1.5 }

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
        return AxisScore(axis: .capitalAllocation, score: final,
                         headline: headline, rationale: rationale)
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
