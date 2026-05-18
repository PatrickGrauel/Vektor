import SwiftUI

/// "What does today's money buy in 10 years? What return do I need
/// just to keep up?" Two-way conversion plus the break-even nominal
/// return needed for a chosen real return.
struct InflationForm: View {
    @AppStorage("tally.finance.infl.amount")     private var amount: Double = 10000
    @AppStorage("tally.finance.infl.years")      private var years: Double = 10
    @AppStorage("tally.finance.infl.rate")       private var inflationRate: Double = 2.5
    @AppStorage("tally.finance.infl.realReturn") private var realReturn: Double = 1.5
    @AppStorage("tally.finance.infl.curr")       private var currency: String = "EUR"

    var body: some View {
        Form {
            futureValueSection
            presentValueSection
            breakEvenSection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(TallyTheme.background)
    }

    private var futureValueSection: some View {
        let futureCost = InflationMath.futureCost(
            presentValue: amount,
            years: years,
            inflationRate: inflationRate / 100.0
        )
        let lostPurchasing = amount - InflationMath.presentValueOf(
            future: amount,
            years: years,
            inflationRate: inflationRate / 100.0
        )
        return Section {
            LabeledContent("Today's amount") {
                HStack {
                    TextField("", value: $amount, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                    CurrencyField(code: $currency)
                }
            }
            LabelledSlider(label: "Years from now",
                           value: $years,
                           range: 1...50,
                           step: 1,
                           format: "%.0f",
                           unit: "yr")
            LabelledSlider(label: "Annual inflation",
                           value: $inflationRate,
                           range: 0...12,
                           step: 0.1,
                           format: "%.1f",
                           unit: "%")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2),
                      spacing: 10) {
                MetricBox(
                    value: formatMoney(futureCost),
                    label: "Will cost in \(Int(years)) years",
                    hint: "nominal",
                    tone: .accent
                )
                MetricBox(
                    value: formatMoney(lostPurchasing),
                    label: "Purchasing power lost",
                    hint: "if you hold cash",
                    tone: .bad
                )
            }
        } header: {
            Text("Future cost").font(.headline)
        } footer: {
            Text("\(formatMoney(amount)) sitting in cash at \(String(format: "%.1f", inflationRate))% inflation will feel like \(formatMoney(amount - lostPurchasing)) in \(Int(years)) years. The number on the bank statement stays \(formatMoney(amount)); what it buys does not.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var presentValueSection: some View {
        let pv = InflationMath.presentValueOf(
            future: amount,
            years: years,
            inflationRate: inflationRate / 100.0
        )
        return Section {
            MetricBox(
                value: formatMoney(pv),
                label: "What \(formatMoney(amount)) in \(Int(years)) years is worth today",
                tone: .neutral
            )
        } header: {
            Text("Present value of a future amount").font(.headline)
        } footer: {
            Text("Useful when comparing a future payment (a buyout, an inheritance, a lottery payout) against a smaller-but-immediate alternative.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var breakEvenSection: some View {
        let breakEven = InflationMath.breakEvenRate(
            realReturn: realReturn / 100.0,
            inflationRate: inflationRate / 100.0
        )
        return Section {
            LabelledSlider(label: "Target real return",
                           value: $realReturn,
                           range: -2...8,
                           step: 0.1,
                           format: "%.1f",
                           unit: "%")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2),
                      spacing: 10) {
                MetricBox(
                    value: String(format: "%.2f%%", breakEven * 100),
                    label: "Required nominal return",
                    hint: "to net \(String(format: "%.1f", realReturn))% real",
                    tone: .accent
                )
                MetricBox(
                    value: String(format: "%.2f%%", (breakEven - inflationRate / 100) * 100),
                    label: "Gap to inflation",
                    tone: realReturn >= 0 ? .good : .bad
                )
            }
        } header: {
            Text("Real-return target").font(.headline)
        } footer: {
            Text("A 0% real return means just keeping up with inflation. 2-3% is roughly what bonds historically deliver; 4-7% real is the long-run equity range.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
