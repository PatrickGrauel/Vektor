import Foundation

/// Swift mirror of the JS `loan` / `compound` / `tip` helpers — used by
/// the Finance pane forms. Keeping them Swift-side means the pane doesn't
/// have to round-trip through the JSContext for every slider movement.
enum FinanceMath {

    // MARK: - Loan

    struct LoanResult {
        let monthlyPayment: Double
        let totalCost: Double
        let totalInterest: Double
        /// Months actually paid (matters when an extra payment is in play —
        /// users pay off early). Equals `term * 12` when extra = 0.
        let monthsPaid: Int
        let amortization: [AmortizationRow]
    }

    struct AmortizationRow {
        let month: Int
        let interest: Double
        let principal: Double
        let balance: Double
    }

    /// Monthly payment + amortization, optionally with a flat monthly
    /// prepayment. The prepayment is applied directly to principal each
    /// month, shortening the loan and reducing total interest.
    static func loan(principal: Double,
                     annualRatePercent: Double,
                     termYears: Int,
                     extraMonthly: Double = 0) -> LoanResult {
        let n = max(termYears, 0) * 12
        let r = annualRatePercent / 100.0 / 12.0
        let baseMonthly: Double
        if n == 0 {
            baseMonthly = 0
        } else if r == 0 {
            baseMonthly = principal / Double(n)
        } else {
            let factor = pow(1 + r, Double(n))
            baseMonthly = principal * r * factor / (factor - 1)
        }

        var rows: [AmortizationRow] = []
        var balance = principal
        var totalPaid: Double = 0
        var monthsPaid = 0
        let extra = max(extraMonthly, 0)

        for month in 1...max(n, 1) {
            let interest = balance * r
            // Pay the scheduled amount + the extra, capped at the remaining
            // balance + interest so the final payment doesn't overshoot.
            var totalPayment = baseMonthly + extra
            if totalPayment > balance + interest {
                totalPayment = balance + interest
            }
            let principalPaid = totalPayment - interest
            balance -= principalPaid
            totalPaid += totalPayment
            monthsPaid = month
            rows.append(AmortizationRow(
                month: month,
                interest: interest,
                principal: principalPaid,
                balance: max(balance, 0)
            ))
            if balance <= 0.005 { break }
            if n == 0 { break }
        }

        return LoanResult(
            monthlyPayment: baseMonthly,
            totalCost: totalPaid,
            totalInterest: totalPaid - principal,
            monthsPaid: monthsPaid,
            amortization: rows
        )
    }

    // MARK: - Investment

    struct InvestmentResult {
        /// Future value in *nominal* (face-value) currency.
        let futureValue: Double
        /// Future value adjusted for inflation — what FV is worth in
        /// today's purchasing power.
        let realFutureValue: Double
        let totalContributed: Double
        let interestEarned: Double
        /// Year-end snapshots. Each row carries both the nominal balance
        /// and its inflation-adjusted equivalent so the chart can plot
        /// both lines.
        let yearlyBalance: [YearBalance]
    }

    struct YearBalance {
        let year: Int
        let balance: Double
        let realBalance: Double
    }

    static func investment(initial: Double,
                           monthly: Double,
                           annualRatePercent: Double,
                           years: Int,
                           inflationPercent: Double = 0) -> InvestmentResult {
        let r = annualRatePercent / 100.0 / 12.0
        let inflMonthly = inflationPercent / 100.0 / 12.0
        let totalMonths = max(years, 0) * 12

        var balance = initial
        var contributed = initial
        // Cumulative inflation factor: `(1 + monthly inflation)^months`.
        // Divide nominal balance by this to get today's purchasing power.
        var inflationFactor: Double = 1
        var yearly: [YearBalance] = [YearBalance(year: 0, balance: initial, realBalance: initial)]

        for month in 1...max(totalMonths, 1) {
            balance = balance * (1 + r) + monthly
            contributed += monthly
            inflationFactor *= (1 + inflMonthly)
            if month % 12 == 0 {
                let real = inflationFactor > 0 ? balance / inflationFactor : balance
                yearly.append(YearBalance(year: month / 12,
                                          balance: balance,
                                          realBalance: real))
            }
            if totalMonths == 0 { break }
        }
        if totalMonths == 0 {
            balance = initial
            contributed = initial
            yearly = [YearBalance(year: 0, balance: initial, realBalance: initial)]
            inflationFactor = 1
        }

        let real = inflationFactor > 0 ? balance / inflationFactor : balance
        return InvestmentResult(
            futureValue: balance,
            realFutureValue: real,
            totalContributed: contributed,
            interestEarned: balance - contributed,
            yearlyBalance: yearly
        )
    }

    // MARK: - Formatting

    static func money(_ value: Double, code: String) -> String {
        let dp = max(0, min(14, UserDefaults.standard.object(forKey: "vektor.precision") as? Int ?? 2))
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = " "
        formatter.minimumFractionDigits = dp
        formatter.maximumFractionDigits = dp
        let numStr = formatter.string(from: NSNumber(value: value)) ?? String(value)
        return "\(numStr) \(code)"
    }

    static func payoffDate(years: Int) -> String {
        let cal = Calendar(identifier: .gregorian)
        let end = cal.date(byAdding: .year, value: years, to: Date()) ?? Date()
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "MMM yyyy"
        return fmt.string(from: end)
    }

    /// "8 yr 4 mo" — human-friendly months → years+months. Returns "0 mo"
    /// for zero, "N mo" for less than a year.
    static func formatMonths(_ months: Int) -> String {
        if months <= 0 { return "0 mo" }
        if months < 12 { return "\(months) mo" }
        let y = months / 12
        let m = months % 12
        if m == 0 { return "\(y) yr" }
        return "\(y) yr \(m) mo"
    }
}
