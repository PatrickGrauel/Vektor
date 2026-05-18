import SwiftUI

/// "Am I going to be okay?" — compound-growth accumulation through
/// retirement age, then inflation-adjusted withdrawals until the
/// pot runs out. Verdict in the dashboard makes the answer obvious.
struct RetirementForm: View {
    @AppStorage("tally.finance.retire.currentAge")    private var currentAge: Double = 35
    @AppStorage("tally.finance.retire.retireAge")     private var retireAge: Double = 65
    @AppStorage("tally.finance.retire.currentSaved")  private var currentSaved: Double = 50000
    @AppStorage("tally.finance.retire.monthly")       private var monthly: Double = 800
    @AppStorage("tally.finance.retire.growthReturn")  private var growthReturn: Double = 6
    @AppStorage("tally.finance.retire.spending")      private var spending: Double = 40000
    @AppStorage("tally.finance.retire.withdrawReturn") private var withdrawReturn: Double = 4
    @AppStorage("tally.finance.retire.inflation")     private var inflation: Double = 2.5
    @AppStorage("tally.finance.retire.curr")          private var currency: String = "EUR"

    private var inputs: RetirementMath.Inputs {
        RetirementMath.Inputs(
            currentAge: Int(currentAge),
            retirementAge: Int(retireAge),
            currentSavings: currentSaved,
            monthlyContribution: monthly,
            growthReturn: growthReturn / 100.0,
            annualRetirementSpending: spending,
            withdrawalReturn: withdrawReturn / 100.0,
            inflation: inflation / 100.0
        )
    }
    private var result: RetirementMath.Outputs { RetirementMath.project(inputs) }

    var body: some View {
        Form {
            dashboardSection
            workingYearsSection
            retirementYearsSection
            commentarySection
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
                    value: formatMoney(result.balanceAtRetirement),
                    label: "At retirement",
                    hint: "age \(Int(retireAge))",
                    tone: .accent
                )
                MetricBox(
                    value: "\(Int(result.yearsFunded)) yr",
                    label: "Years funded",
                    hint: "until age \(Int(retireAge) + Int(result.yearsFunded))",
                    tone: verdictTone
                )
                MetricBox(
                    value: verdictLabel,
                    label: "Verdict",
                    tone: verdictTone
                )
            }
        } header: {
            Text("Outlook").font(.headline)
        }
    }

    private var workingYearsSection: some View {
        Section {
            LabelledSlider(label: "Current age",
                           value: $currentAge,
                           range: 18...80,
                           step: 1,
                           format: "%.0f")
            LabelledSlider(label: "Retirement age",
                           value: $retireAge,
                           range: max(currentAge + 1, 50)...85,
                           step: 1,
                           format: "%.0f")
            LabeledContent("Saved so far") {
                HStack {
                    TextField("", value: $currentSaved, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                    CurrencyField(code: $currency)
                }
            }
            LabeledContent("Monthly contribution") {
                HStack {
                    TextField("", value: $monthly, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                    Text(currency).foregroundStyle(TallyTheme.muted)
                }
            }
            LabelledSlider(label: "Pre-retirement return",
                           value: $growthReturn,
                           range: 0...10,
                           step: 0.1,
                           format: "%.1f",
                           unit: "%")
        } header: {
            Text("Working years").font(.headline)
        } footer: {
            Text("Long-run equities have averaged 7% real / 9–10% nominal in many markets; bonds 1–3%. A balanced portfolio sits at 5–7%.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var retirementYearsSection: some View {
        Section {
            LabeledContent("Annual spending in retirement") {
                HStack {
                    TextField("", value: $spending, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                    Text(currency).foregroundStyle(TallyTheme.muted)
                }
            }
            LabelledSlider(label: "Post-retirement return",
                           value: $withdrawReturn,
                           range: 0...8,
                           step: 0.1,
                           format: "%.1f",
                           unit: "%")
            LabelledSlider(label: "Inflation assumption",
                           value: $inflation,
                           range: 0...8,
                           step: 0.1,
                           format: "%.1f",
                           unit: "%")
        } header: {
            Text("Retirement years").font(.headline)
        } footer: {
            Text("The 4% rule says ~25× annual spending lasts 30+ years; that maps to ~3-4% real return + 2-3% inflation here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var commentarySection: some View {
        let years = result.yearsFunded
        let needAtRetirement = spending * 25                 // 4% rule rough ballpark
        let gap = needAtRetirement - result.balanceAtRetirement
        Section {
            VStack(alignment: .leading, spacing: 6) {
                if years < 20 {
                    Text("Shortfall.")
                        .font(.callout.bold())
                        .foregroundStyle(TallyTheme.statusBad)
                    Text("The balance runs out before \(Int(retireAge) + 20). Closing the gap usually means some combination of: contributing more now, delaying retirement a few years, or planning a lower annual spend.")
                        .font(.callout)
                } else if years < 35 {
                    Text("Adequate, with a buffer to keep an eye on.")
                        .font(.callout.bold())
                        .foregroundStyle(TallyTheme.statusCaution)
                    Text("The funds cover \(Int(years)) years of retirement. Comfortable if you live an average lifespan and inflation stays near your assumption.")
                        .font(.callout)
                } else {
                    Text("Fully funded with margin.")
                        .font(.callout.bold())
                        .foregroundStyle(TallyTheme.statusGood)
                    Text("Funds last \(Int(years))+ years. You could reasonably retire earlier, spend more, or shift to more conservative allocations as you approach retirement.")
                        .font(.callout)
                }
                Divider()
                Text("4%-rule benchmark: ~\(formatMoney(needAtRetirement)) at retirement for \(formatMoney(spending))/yr spending. You're projected to have \(formatMoney(result.balanceAtRetirement)) (\(gap >= 0 ? "−" : "+")\(formatMoney(abs(gap))) vs benchmark).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Take").font(.headline)
        }
    }

    private var verdictLabel: String {
        switch result.verdict {
        case .shortfall:    return "Short"
        case .adequate:     return "Adequate"
        case .fullyFunded:  return "Funded"
        }
    }
    private var verdictTone: MetricBox.Tone {
        switch result.verdict {
        case .shortfall:    return .bad
        case .adequate:     return .caution
        case .fullyFunded:  return .good
        }
    }

    private func formatMoney(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency.isEmpty ? "USD" : currency
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: v)) ?? "\(Int(v))"
    }
}
