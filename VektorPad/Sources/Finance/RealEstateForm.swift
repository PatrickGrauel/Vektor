import SwiftUI

struct RealEstateForm: View {
    @AppStorage("vektor.finance.currency") private var currency = "EUR"
    @AppStorage("vektor.finance.re.price") private var price = 500_000.0
    @AppStorage("vektor.finance.re.down") private var downPct = 25.0
    @AppStorage("vektor.finance.re.rate") private var ratePct = 6.5
    @AppStorage("vektor.finance.re.term") private var term = 30
    @AppStorage("vektor.finance.re.rent") private var rent = 3_500.0
    @AppStorage("vektor.finance.re.vacancy") private var vacancy = 5.0
    @AppStorage("vektor.finance.re.tax") private var tax = 4_500.0
    @AppStorage("vektor.finance.re.insurance") private var insurance = 1_200.0
    @AppStorage("vektor.finance.re.maint") private var maint = 8.0
    @AppStorage("vektor.finance.re.appreciation") private var appreciation = 3.0
    @AppStorage("vektor.finance.re.hold") private var hold = 10

    private var result: RealEstateMath.Result {
        var i = RealEstateMath.Inputs()
        i.purchasePrice = price
        i.downPaymentPercent = downPct
        i.mortgageRatePercent = ratePct
        i.loanTermYears = Double(max(1, term))
        i.monthlyRent = rent
        i.vacancyPercent = vacancy
        i.propertyTaxAnnual = tax
        i.insuranceAnnual = insurance
        i.maintenancePercentOfRent = maint
        i.appreciationPercent = appreciation
        i.holdYears = max(1, hold)
        return RealEstateMath.analyze(i)
    }

    var body: some View {
        let r = result
        Form {
            Section("Property & financing") {
                CurrencyField(code: $currency)
                NumberField(label: "Purchase price", value: $price, suffix: currency)
                NumberField(label: "Down payment", value: $downPct, suffix: "%")
                NumberField(label: "Mortgage rate", value: $ratePct, suffix: "%/yr")
                IntStepperField(label: "Loan term", value: $term, range: 1...40, suffix: "yr")
            }
            Section("Income & expenses") {
                NumberField(label: "Monthly rent", value: $rent, suffix: currency)
                NumberField(label: "Vacancy", value: $vacancy, suffix: "%")
                NumberField(label: "Property tax / yr", value: $tax, suffix: currency)
                NumberField(label: "Insurance / yr", value: $insurance, suffix: currency)
                NumberField(label: "Maintenance", value: $maint, suffix: "% of rent")
            }
            Section("Hold") {
                NumberField(label: "Appreciation", value: $appreciation, suffix: "%/yr")
                IntStepperField(label: "Hold period", value: $hold, range: 1...40, suffix: "yr")
            }
            Section("Analysis") {
                MetricGrid {
                    MetricBox(title: "Monthly mortgage",
                              value: FinanceMath.money(r.monthlyMortgagePayment, code: currency))
                    MetricBox(title: "Cash flow / yr",
                              value: FinanceMath.money(r.y1CashFlow, code: currency),
                              tone: r.y1CashFlow >= 0 ? .good : .bad)
                    MetricBox(title: "Cap rate",
                              value: String(format: "%.2f%%", r.capRate), tone: .accent)
                    MetricBox(title: "Cash-on-cash",
                              value: String(format: "%.2f%%", r.cashOnCashReturn),
                              tone: r.cashOnCashReturn >= 0 ? .accent : .bad)
                    MetricBox(title: "DSCR",
                              value: r.dscr.isFinite ? String(format: "%.2f", r.dscr) : "∞",
                              tone: r.dscr >= 1.25 ? .good : (r.dscr >= 1 ? .caution : .bad))
                    MetricBox(title: "IRR (\(max(1, hold)) yr)",
                              value: r.irr.map { String(format: "%.1f%%", $0) } ?? "—",
                              tone: .accent)
                    MetricBox(title: "Cash invested",
                              value: FinanceMath.money(r.cashInvested, code: currency))
                    MetricBox(title: "Equity multiple",
                              value: String(format: "%.2f×", r.equityMultiple),
                              tone: r.equityMultiple >= 1 ? .good : .bad)
                }
            }
        }
        .financeFormChrome("Real estate")
    }
}
