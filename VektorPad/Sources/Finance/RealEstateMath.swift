import Foundation

/// Professional real-estate investment analysis. Computes every metric a
/// buy-and-hold investor / lender checks before pulling the trigger on a
/// deal: cap rate, cash-on-cash, DSCR, NOI, GRM, year-by-year P&L, IRR,
/// equity multiple, and break-even points.
///
/// All `Inputs` arrive in human units (purchase price in chosen currency,
/// percentages 0–100, rents per month). The result struct uses the same
/// currency throughout — caller decides whether that's USD, EUR, GBP, etc.
enum RealEstateMath {

    // MARK: - Inputs

    struct Inputs: Equatable {
        // Property
        var purchasePrice: Double           = 500_000
        var closingCostsPercent: Double     = 3.0      // of purchase price
        // Financing
        var downPaymentPercent: Double      = 25.0     // of purchase price
        var mortgageRatePercent: Double     = 6.5
        var loanTermYears: Double           = 30
        // Rental income
        var monthlyRent: Double             = 3_500
        var vacancyPercent: Double          = 5.0      // of gross rent
        var otherMonthlyIncome: Double      = 0        // parking, laundry, etc.
        var annualRentGrowthPercent: Double = 3.0
        // Operating expenses
        var propertyTaxAnnual: Double       = 4_500
        var insuranceAnnual: Double         = 1_200
        var maintenancePercentOfRent: Double = 8.0
        var propertyMgmtPercentOfRent: Double = 8.0
        var hoaMonthly: Double              = 0
        var capExPercentOfRent: Double      = 5.0
        var utilitiesAnnual: Double         = 0
        // Hold + exit
        var appreciationPercent: Double     = 3.0
        var holdYears: Int                  = 10
        var sellingCostsPercent: Double     = 6.0      // of sale price
    }

    // MARK: - Result

    struct YearProjection: Equatable {
        let year: Int
        let grossRent: Double
        let vacancyLoss: Double
        let otherIncome: Double
        let effectiveGrossIncome: Double
        let operatingExpenses: Double
        let noi: Double
        let debtService: Double
        let cashFlow: Double
        let loanBalance: Double
        let principalPaid: Double
        let propertyValue: Double
        let cumulativeCashFlow: Double
        let equity: Double                       // value − loan balance
    }

    struct Result: Equatable {
        // Derived financing
        let downPayment: Double
        let closingCosts: Double
        let loanAmount: Double
        let cashInvested: Double                 // down + closing
        let monthlyMortgagePayment: Double       // P&I

        // Year-1 P&L
        let y1GrossRent: Double
        let y1VacancyLoss: Double
        let y1OtherIncome: Double
        let y1EffectiveGrossIncome: Double
        let y1OperatingExpenses: Double
        let y1NOI: Double
        let y1DebtService: Double
        let y1CashFlow: Double                   // monthly average derived
        let y1OperatingExpenseRatio: Double      // OpEx / EGI

        // Headline metrics
        let capRate: Double                      // NOI / price (no-leverage yield)
        let cashOnCashReturn: Double             // Y1 cash flow / cash invested
        let dscr: Double                         // NOI / debt service (lender's view)
        let grm: Double                          // price / annual gross rent
        let rentRatio: Double                    // monthly rent / price (1% rule)

        // Projection + sale
        let yearByYear: [YearProjection]
        let propertyValueAtSale: Double
        let loanBalanceAtSale: Double
        let netSaleProceeds: Double              // after selling costs
        let cashFromSale: Double                 // net proceeds − loan balance
        let totalCashFlow: Double                // sum of annual CF over hold
        let totalReturn: Double                  // cash flow + cash from sale − cash invested
        let equityMultiple: Double               // (cf + sale) / invested
        let irr: Double?                         // annualised, nil if no convergence

        // Sensitivity
        let breakEvenMonthlyRent: Double         // rent for Y1 CF = 0
        let breakEvenOccupancyPercent: Double    // occupancy for Y1 CF = 0
    }

    // MARK: - Public API

    static func analyze(_ inputs: Inputs) -> Result {
        let p = inputs

        // 1. Financing primitives
        let downPayment   = p.purchasePrice * p.downPaymentPercent / 100
        let closingCosts  = p.purchasePrice * p.closingCostsPercent / 100
        let loanAmount    = max(p.purchasePrice - downPayment, 0)
        let cashInvested  = downPayment + closingCosts
        let monthsTotal   = Int(p.loanTermYears * 12)
        let monthlyRate   = p.mortgageRatePercent / 100 / 12

        let monthlyPI: Double
        if monthsTotal == 0 {
            monthlyPI = 0
        } else if monthlyRate == 0 {
            monthlyPI = loanAmount / Double(monthsTotal)
        } else {
            let factor = pow(1 + monthlyRate, Double(monthsTotal))
            monthlyPI = loanAmount * monthlyRate * factor / (factor - 1)
        }

        // 2. Year-by-year simulation. We re-derive every figure annually so
        //    the projection table is honest about rent growth and remaining
        //    loan balance, not just a back-of-envelope ×N.
        var year: [YearProjection] = []
        var loanBalance = loanAmount
        var monthlyRent = p.monthlyRent
        var cumCF: Double = 0

        for y in 1...max(p.holdYears, 1) {
            let grossRent      = monthlyRent * 12
            let vacancyLoss    = grossRent * (p.vacancyPercent / 100)
            let otherIncome    = p.otherMonthlyIncome * 12
            let egi            = grossRent - vacancyLoss + otherIncome
            let opEx           = annualOperatingExpenses(monthlyRent: monthlyRent, p: p)
            let noi            = egi - opEx
            let debtService    = monthlyPI * 12
            let cashFlow       = noi - debtService

            // Amortise the loan one year forward; track principal paid.
            let (newBalance, principalPaid) = amortiseOneYear(
                balance: loanBalance,
                monthlyPayment: monthlyPI,
                monthlyRate: monthlyRate
            )
            loanBalance = newBalance

            let propertyValue = p.purchasePrice * pow(1 + p.appreciationPercent / 100, Double(y))
            cumCF += cashFlow

            year.append(YearProjection(
                year: y,
                grossRent: grossRent,
                vacancyLoss: vacancyLoss,
                otherIncome: otherIncome,
                effectiveGrossIncome: egi,
                operatingExpenses: opEx,
                noi: noi,
                debtService: debtService,
                cashFlow: cashFlow,
                loanBalance: loanBalance,
                principalPaid: principalPaid,
                propertyValue: propertyValue,
                cumulativeCashFlow: cumCF,
                equity: propertyValue - loanBalance
            ))

            monthlyRent *= (1 + p.annualRentGrowthPercent / 100)
            if p.holdYears == 0 { break }
        }

        // 3. Headline metrics derived from year-1.
        // `year.first!` is safe: the loop above iterates over
        // `1...max(p.holdYears, 1)`, which guarantees at least one
        // iteration and one appended `YearProjection`.
        let y1 = year.first!
        let capRate = p.purchasePrice > 0 ? y1.noi / p.purchasePrice * 100 : 0
        let coc     = cashInvested > 0 ? y1.cashFlow / cashInvested * 100 : 0
        let dscr    = y1.debtService > 0 ? y1.noi / y1.debtService : .infinity
        let grm     = y1.grossRent > 0 ? p.purchasePrice / y1.grossRent : 0
        let rentRatio = p.purchasePrice > 0 ? p.monthlyRent / p.purchasePrice * 100 : 0
        let opExRatio = y1.effectiveGrossIncome > 0
            ? y1.operatingExpenses / y1.effectiveGrossIncome * 100
            : 0

        // 4. Exit math. Same invariant as above — `year` is non-empty
        // because the loop runs at least once.
        let last = year.last!
        let saleValue = last.propertyValue
        let sellingCosts = saleValue * (p.sellingCostsPercent / 100)
        let netSale = saleValue - sellingCosts
        let cashFromSale = netSale - last.loanBalance
        let totalReturn = cumCF + cashFromSale - cashInvested
        let equityMultiple = cashInvested > 0
            ? (cumCF + cashFromSale) / cashInvested
            : 0

        // 5. IRR — initial outlay at year 0, annual cash flow Y1..N-1,
        //    Y[N] = cash flow + cash from sale.
        var cashflows: [Double] = []
        cashflows.append(-cashInvested)
        for (i, yr) in year.enumerated() {
            if i == year.count - 1 {
                cashflows.append(yr.cashFlow + cashFromSale)
            } else {
                cashflows.append(yr.cashFlow)
            }
        }
        let irr = solveIRR(cashflows: cashflows)

        // 6. Sensitivity: rent that yields Y1 cash flow = 0
        let beRent = breakEvenMonthlyRent(p: p, monthlyPI: monthlyPI)
        let beOcc  = breakEvenOccupancyPercent(p: p, monthlyPI: monthlyPI)

        return Result(
            downPayment: downPayment,
            closingCosts: closingCosts,
            loanAmount: loanAmount,
            cashInvested: cashInvested,
            monthlyMortgagePayment: monthlyPI,
            y1GrossRent: y1.grossRent,
            y1VacancyLoss: y1.vacancyLoss,
            y1OtherIncome: y1.otherIncome,
            y1EffectiveGrossIncome: y1.effectiveGrossIncome,
            y1OperatingExpenses: y1.operatingExpenses,
            y1NOI: y1.noi,
            y1DebtService: y1.debtService,
            y1CashFlow: y1.cashFlow,
            y1OperatingExpenseRatio: opExRatio,
            capRate: capRate,
            cashOnCashReturn: coc,
            dscr: dscr,
            grm: grm,
            rentRatio: rentRatio,
            yearByYear: year,
            propertyValueAtSale: saleValue,
            loanBalanceAtSale: last.loanBalance,
            netSaleProceeds: netSale,
            cashFromSale: cashFromSale,
            totalCashFlow: cumCF,
            totalReturn: totalReturn,
            equityMultiple: equityMultiple,
            irr: irr,
            breakEvenMonthlyRent: beRent,
            breakEvenOccupancyPercent: beOcc
        )
    }

    // MARK: - Building blocks

    /// Annual operating expenses, given the current year's monthly rent
    /// (so rent-proportional items grow with rent).
    private static func annualOperatingExpenses(monthlyRent: Double, p: Inputs) -> Double {
        let annualRent = monthlyRent * 12
        let maintenance = annualRent * (p.maintenancePercentOfRent / 100)
        let mgmt        = annualRent * (p.propertyMgmtPercentOfRent / 100)
        let capEx       = annualRent * (p.capExPercentOfRent / 100)
        let hoa         = p.hoaMonthly * 12
        return p.propertyTaxAnnual + p.insuranceAnnual + p.utilitiesAnnual
            + maintenance + mgmt + capEx + hoa
    }

    /// Amortise one calendar year (12 months) forward. Returns
    /// (newBalance, principalPaid) so the caller can record equity build.
    private static func amortiseOneYear(balance: Double,
                                        monthlyPayment: Double,
                                        monthlyRate: Double) -> (Double, Double) {
        guard balance > 0 else { return (0, 0) }
        var b = balance
        var principalPaid: Double = 0
        for _ in 0..<12 {
            let interest = b * monthlyRate
            var principal = monthlyPayment - interest
            if principal > b { principal = b }
            b -= principal
            principalPaid += principal
            if b <= 0.005 { b = 0; break }
        }
        return (b, principalPaid)
    }

    /// Internal rate of return via Newton-Raphson with bracketing. Returns
    /// the annualised IRR as a percentage (e.g. 9.5 means 9.5%/yr). Returns
    /// nil if the solver can't converge — typically because the cash-flow
    /// series doesn't change sign and so no positive IRR exists.
    private static func solveIRR(cashflows: [Double]) -> Double? {
        guard cashflows.count >= 2 else { return nil }
        // Need at least one positive and one negative to have a real IRR.
        if !(cashflows.contains(where: { $0 > 0 }) && cashflows.contains(where: { $0 < 0 })) {
            return nil
        }
        var rate: Double = 0.10
        for _ in 0..<200 {
            var npv: Double = 0
            var derivative: Double = 0
            for (t, cf) in cashflows.enumerated() {
                let denom = pow(1 + rate, Double(t))
                npv += cf / denom
                if t > 0 {
                    derivative -= Double(t) * cf / (denom * (1 + rate))
                }
            }
            if abs(derivative) < 1e-12 { return nil }
            let newRate = rate - npv / derivative
            // Guard against rate diverging into impossible territory.
            if newRate.isNaN || newRate <= -0.999 { return nil }
            if abs(newRate - rate) < 1e-7 {
                return newRate * 100
            }
            rate = newRate
        }
        return nil
    }

    /// Monthly rent at which the year-1 cash flow is zero. Solved
    /// algebraically because cash flow is linear in rent (vacancy %, rent-
    /// proportional opex, etc. are all linear).
    private static func breakEvenMonthlyRent(p: Inputs, monthlyPI: Double) -> Double {
        // y1 cash flow as a function of `r` (monthly rent):
        //
        //   gross           = r * 12
        //   vacancy loss    = r * 12 * v
        //   egi             = r * 12 * (1 - v) + other * 12
        //   rent-prop opex  = r * 12 * (m + mgmt + capex)
        //   fixed opex      = tax + ins + util + hoa*12
        //   noi             = r * 12 * (1 - v - m - mgmt - capex) + other*12 - fixed
        //   cash flow       = noi - 12 * pi
        //
        //   set cash flow = 0:
        //     r = (12*pi + fixed - other*12) / (12 * (1 - v - m - mgmt - capex))
        let v = p.vacancyPercent / 100
        let m = p.maintenancePercentOfRent / 100
        let mg = p.propertyMgmtPercentOfRent / 100
        let cx = p.capExPercentOfRent / 100
        let coeff = 1 - v - m - mg - cx
        guard coeff > 0 else { return .infinity }
        let fixed = p.propertyTaxAnnual + p.insuranceAnnual + p.utilitiesAnnual + p.hoaMonthly * 12
        let numerator = 12 * monthlyPI + fixed - p.otherMonthlyIncome * 12
        let r = numerator / (12 * coeff)
        return max(r, 0)
    }

    /// Occupancy percentage (i.e. 1 − vacancy) at which year-1 cash flow
    /// is zero, holding the input rent fixed. Returns 100 if even full
    /// occupancy can't make the deal work, 0 if any occupancy is fine.
    private static func breakEvenOccupancyPercent(p: Inputs, monthlyPI: Double) -> Double {
        // Linear in occupancy o = 1 - v:
        //   egi           = r*12*o + other*12
        //   rent-prop opex = r*12*o*(m + mgmt + capex)   (assumed to scale with collected rent)
        //
        // To keep the math conservative we leave rent-prop opex tied to
        // GROSS rent (not collected). Then:
        //   cash flow = r*12*o + other*12 - r*12*(m+mgmt+cx) - fixed - 12*pi
        //   solve for o where cash flow = 0:
        //     o = (fixed + 12*pi + r*12*(m+mgmt+cx) - other*12) / (r*12)
        let r = p.monthlyRent
        guard r > 0 else { return 100 }
        let m = p.maintenancePercentOfRent / 100
        let mg = p.propertyMgmtPercentOfRent / 100
        let cx = p.capExPercentOfRent / 100
        let fixed = p.propertyTaxAnnual + p.insuranceAnnual + p.utilitiesAnnual + p.hoaMonthly * 12
        let rentOpEx = r * 12 * (m + mg + cx)
        let o = (fixed + 12 * monthlyPI + rentOpEx - p.otherMonthlyIncome * 12) / (r * 12)
        return min(max(o * 100, 0), 100)
    }
}
