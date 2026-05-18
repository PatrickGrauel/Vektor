import SwiftUI

/// "I want X by Y, how much do I need to save monthly?" Solves for
/// the required monthly contribution given a target, time horizon,
/// starting balance, and expected return. The reverse view also
/// shows what the user would actually end up with if they save a
/// chosen amount per month instead.
struct SavingsGoalForm: View {
    @AppStorage("tally.finance.savings.target")  private var target: Double = 50000
    @AppStorage("tally.finance.savings.current") private var current: Double = 5000
    @AppStorage("tally.finance.savings.months")  private var months: Double = 36
    @AppStorage("tally.finance.savings.return")  private var annualReturn: Double = 4
    @AppStorage("tally.finance.savings.curr")    private var currency: String = "EUR"

    private var inputs: SavingsMath.Inputs {
        SavingsMath.Inputs(
            presentValue: current,
            targetValue: target,
            monthsToGoal: Int(months),
            annualReturn: annualReturn / 100.0
        )
    }
    private var result: SavingsMath.Outputs { SavingsMath.solve(inputs) }

    var body: some View {
        Form {
            dashboardSection
            inputSection
            breakdownSection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(TallyTheme.background)
    }

    private var dashboardSection: some View {
        Section {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3),
                      spacing: 10) {
                MetricBox(
                    value: formatMoney(max(0, result.requiredMonthlyContribution)),
                    label: "Required / month",
                    tone: result.requiredMonthlyContribution > 0 ? .accent : .good
                )
                MetricBox(
                    value: formatMoney(result.totalContributions),
                    label: "You contribute",
                    hint: "over \(Int(months)) months"
                )
                MetricBox(
                    value: formatMoney(result.totalInterest),
                    label: "Interest earned",
                    tone: result.totalInterest >= 0 ? .good : .bad
                )
            }
        } header: {
            Text("Goal").font(.headline)
        } footer: {
            footerCommentary
        }
    }

    @ViewBuilder
    private var footerCommentary: some View {
        if result.requiredMonthlyContribution <= 0 {
            Text("You'd already overshoot the goal without contributing anything. Time horizon plus current balance does the work.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if months < 6 {
            Text("Short horizon — most of the heavy lifting is the contribution itself, returns barely matter.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("Interest = \(percentText(result.totalInterest / max(result.totalContributions, 1))) of your contributions over the period.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var inputSection: some View {
        Section {
            LabeledContent("Target amount") {
                HStack {
                    TextField("", value: $target, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                    CurrencyField(code: $currency)
                }
            }
            LabeledContent("Already saved") {
                HStack {
                    TextField("", value: $current, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                    Text(currency).foregroundStyle(TallyTheme.muted)
                }
            }
            LabelledSlider(label: "Months to goal",
                           value: $months,
                           range: 1...360,
                           step: 1,
                           format: "%.0f",
                           unit: "mo")
            LabelledSlider(label: "Expected annual return",
                           value: $annualReturn,
                           range: 0...12,
                           step: 0.1,
                           format: "%.1f",
                           unit: "%")
        } header: {
            Text("Inputs").font(.headline)
        } footer: {
            Text("Use a conservative return for short horizons (under 3 years stay close to cash), 4–6% for a balanced 5-10 year window, 7%+ only for long, equity-heavy horizons.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var breakdownSection: some View {
        Section {
            HStack(spacing: 24) {
                breakdownItem("Start", formatMoney(current))
                breakdownItem("Contributions",
                              "+" + formatMoney(result.totalContributions))
                breakdownItem("Interest",
                              "+" + formatMoney(result.totalInterest))
                Spacer()
                breakdownItem("Target", formatMoney(target), tone: .accent)
            }
        } header: {
            Text("Breakdown").font(.headline)
        }
    }

    private func breakdownItem(_ label: String, _ value: String,
                               tone: MetricBox.Tone = .neutral) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(TallyTheme.muted)
            Text(value)
                .font(.system(.callout, design: .rounded).weight(.medium))
                .foregroundStyle(tone.color)
        }
    }

    private func formatMoney(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency.isEmpty ? "USD" : currency
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: v)) ?? "\(Int(v))"
    }

    private func percentText(_ v: Double) -> String {
        String(format: "%.0f%%", v * 100)
    }
}
