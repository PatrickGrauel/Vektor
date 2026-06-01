import SwiftUI

struct LoanForm: View {
    @AppStorage("vektor.finance.currency") private var currency = "EUR"
    @AppStorage("vektor.finance.loan.principal") private var principal = 250_000.0
    @AppStorage("vektor.finance.loan.rate") private var rate = 5.0
    @AppStorage("vektor.finance.loan.term") private var term = 30
    @AppStorage("vektor.finance.loan.extra") private var extra = 0.0

    var body: some View {
        let res = FinanceMath.loan(principal: principal, annualRatePercent: rate,
                                   termYears: max(1, term), extraMonthly: extra)
        Form {
            Section("Loan") {
                CurrencyField(code: $currency)
                NumberField(label: "Principal", value: $principal, suffix: currency)
                NumberField(label: "Interest rate", value: $rate, suffix: "%/yr")
                IntStepperField(label: "Term", value: $term, range: 1...40, suffix: "yr")
                NumberField(label: "Extra monthly", value: $extra, suffix: currency)
            }
            Section("Result") {
                MetricGrid {
                    MetricBox(title: "Monthly payment",
                              value: FinanceMath.money(res.monthlyPayment, code: currency), tone: .accent)
                    MetricBox(title: "Total interest",
                              value: FinanceMath.money(res.totalInterest, code: currency), tone: .caution)
                    MetricBox(title: "Total cost",
                              value: FinanceMath.money(res.totalCost, code: currency))
                    MetricBox(title: "Payoff in",
                              value: FinanceMath.formatMonths(res.monthsPaid),
                              tone: extra > 0 ? .good : .neutral,
                              hint: extra > 0 ? "with extra payments" : nil)
                }
            }
        }
        .financeFormChrome("Loan")
    }
}
