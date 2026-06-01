import SwiftUI

// MARK: - Savings goal

struct SavingsForm: View {
    @AppStorage("vektor.finance.currency") private var currency = "EUR"
    @AppStorage("vektor.finance.savings.current") private var current = 5_000.0
    @AppStorage("vektor.finance.savings.target") private var target = 25_000.0
    @AppStorage("vektor.finance.savings.months") private var months = 36
    @AppStorage("vektor.finance.savings.return") private var ret = 5.0

    var body: some View {
        let out = SavingsMath.solve(SavingsMath.Inputs(
            presentValue: current, targetValue: target,
            monthsToGoal: max(1, months), annualReturn: ret / 100))
        Form {
            Section("Goal") {
                CurrencyField(code: $currency)
                NumberField(label: "Current savings", value: $current, suffix: currency)
                NumberField(label: "Target", value: $target, suffix: currency)
                IntStepperField(label: "Months to goal", value: $months, range: 1...600, suffix: "mo")
                NumberField(label: "Expected return", value: $ret, suffix: "%/yr")
            }
            Section("Plan") {
                MetricGrid {
                    MetricBox(title: "Monthly needed",
                              value: FinanceMath.money(max(0, out.requiredMonthlyContribution), code: currency),
                              tone: .accent)
                    MetricBox(title: "You contribute",
                              value: FinanceMath.money(out.totalContributions, code: currency))
                    MetricBox(title: "Interest earned",
                              value: FinanceMath.money(out.totalInterest, code: currency), tone: .good)
                    MetricBox(title: "Target",
                              value: FinanceMath.money(target, code: currency))
                }
            }
        }
        .financeFormChrome("Savings goal")
    }
}

// MARK: - Retirement

struct RetirementForm: View {
    @AppStorage("vektor.finance.currency") private var currency = "EUR"
    @AppStorage("vektor.finance.retire.currentAge") private var currentAge = 35
    @AppStorage("vektor.finance.retire.retireAge") private var retireAge = 65
    @AppStorage("vektor.finance.retire.saved") private var saved = 50_000.0
    @AppStorage("vektor.finance.retire.monthly") private var monthly = 800.0
    @AppStorage("vektor.finance.retire.growth") private var growth = 6.0
    @AppStorage("vektor.finance.retire.spending") private var spending = 40_000.0
    @AppStorage("vektor.finance.retire.withdraw") private var withdraw = 4.0
    @AppStorage("vektor.finance.retire.inflation") private var inflation = 2.5

    var body: some View {
        let out = RetirementMath.project(RetirementMath.Inputs(
            currentAge: currentAge, retirementAge: max(currentAge + 1, retireAge),
            currentSavings: saved, monthlyContribution: monthly,
            growthReturn: growth / 100, annualRetirementSpending: spending,
            withdrawalReturn: withdraw / 100, inflation: inflation / 100))
        let verdict: (tone: MetricBox.Tone, label: String) = {
            switch out.verdict {
            case .shortfall:   return (.bad, "Shortfall")
            case .adequate:    return (.caution, "Adequate")
            case .fullyFunded: return (.good, "Fully funded")
            }
        }()
        Form {
            Section("You") {
                CurrencyField(code: $currency)
                IntStepperField(label: "Current age", value: $currentAge, range: 18...80)
                IntStepperField(label: "Retirement age", value: $retireAge, range: 40...85)
                NumberField(label: "Saved so far", value: $saved, suffix: currency)
                NumberField(label: "Monthly contribution", value: $monthly, suffix: currency)
                NumberField(label: "Growth return", value: $growth, suffix: "%/yr")
            }
            Section("Retirement") {
                NumberField(label: "Annual spending", value: $spending, suffix: currency)
                NumberField(label: "Withdrawal return", value: $withdraw, suffix: "%/yr")
                NumberField(label: "Inflation", value: $inflation, suffix: "%/yr")
            }
            Section("Outlook") {
                MetricGrid {
                    MetricBox(title: "At retirement",
                              value: FinanceMath.money(out.balanceAtRetirement, code: currency), tone: .accent)
                    MetricBox(title: "Funds last",
                              value: out.yearsFunded >= 60 ? "60+ yrs" : String(format: "%.0f yrs", out.yearsFunded),
                              tone: verdict.tone)
                    MetricBox(title: "Verdict", value: verdict.label, tone: verdict.tone)
                    MetricBox(title: "Until retirement",
                              value: "\(max(0, retireAge - currentAge)) yrs")
                }
            }
        }
        .financeFormChrome("Retirement")
    }
}

// MARK: - Tip & split

struct TipForm: View {
    @AppStorage("vektor.finance.currency") private var currency = "EUR"
    @AppStorage("vektor.finance.tip.bill") private var bill = 50.0
    @AppStorage("vektor.finance.tip.percent") private var percent = 15.0
    @AppStorage("vektor.finance.tip.people") private var people = 2
    @AppStorage("vektor.finance.tip.roundUp") private var roundUp = false

    var body: some View {
        let tip = bill * percent / 100
        let total = bill + tip
        let rawPer = total / Double(max(1, people))
        let perPerson = roundUp ? rawPer.rounded(.up) : rawPer
        Form {
            Section("Bill") {
                CurrencyField(code: $currency)
                NumberField(label: "Bill amount", value: $bill, suffix: currency)
                NumberField(label: "Tip", value: $percent, suffix: "%")
                IntStepperField(label: "Split between", value: $people, range: 1...50, suffix: "people")
                Toggle("Round up per person", isOn: $roundUp)
            }
            Section("Result") {
                MetricGrid {
                    MetricBox(title: "Tip", value: FinanceMath.money(tip, code: currency), tone: .caution)
                    MetricBox(title: "Total", value: FinanceMath.money(total, code: currency), tone: .accent)
                    MetricBox(title: "Per person", value: FinanceMath.money(perPerson, code: currency), tone: .good)
                    MetricBox(title: "People", value: "\(people)")
                }
            }
        }
        .financeFormChrome("Tip & split")
    }
}

// MARK: - Inflation

struct InflationForm: View {
    @AppStorage("vektor.finance.currency") private var currency = "EUR"
    @AppStorage("vektor.finance.infl.amount") private var amount = 10_000.0
    @AppStorage("vektor.finance.infl.years") private var years = 10.0
    @AppStorage("vektor.finance.infl.rate") private var rate = 2.5

    var body: some View {
        let future = InflationMath.futureCost(presentValue: amount, years: years, inflationRate: rate / 100)
        let todayWorth = InflationMath.presentValueOf(future: amount, years: years, inflationRate: rate / 100)
        let lostPct = amount > 0 ? (1 - todayWorth / amount) * 100 : 0
        Form {
            Section("Scenario") {
                CurrencyField(code: $currency)
                NumberField(label: "Amount today", value: $amount, suffix: currency)
                NumberField(label: "Years ahead", value: $years, suffix: "yr")
                NumberField(label: "Inflation", value: $rate, suffix: "%/yr")
            }
            Section("Result") {
                MetricGrid {
                    MetricBox(title: "Costs in \(Int(years)) yr",
                              value: FinanceMath.money(future, code: currency), tone: .caution)
                    MetricBox(title: "Today's buying power",
                              value: FinanceMath.money(todayWorth, code: currency), tone: .bad)
                    MetricBox(title: "Value lost",
                              value: String(format: "%.1f%%", lostPct), tone: .bad)
                    MetricBox(title: "Amount today",
                              value: FinanceMath.money(amount, code: currency))
                }
            }
        }
        .financeFormChrome("Inflation")
    }
}

// MARK: - Shared chrome

extension View {
    /// Common navigation + background chrome for a finance form.
    func financeFormChrome(_ title: String) -> some View {
        self
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(VektorTheme.background)
    }
}
