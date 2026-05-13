import SwiftUI

struct TipForm: View {
    @AppStorage("tally.finance.tip.bill")     private var bill: Double = 86.50
    @AppStorage("tally.finance.tip.percent")  private var tipPercent: Double = 18
    @AppStorage("tally.finance.tip.people")   private var people: Int = 2
    @AppStorage("tally.finance.tip.currency") private var currency: String = "USD"
    @AppStorage("tally.finance.tip.roundUp")  private var roundUp: Bool = false

    var body: some View {
        Form {
            Section("Bill") {
                LabeledContent("Subtotal") {
                    HStack(spacing: 6) {
                        TextField("", value: $bill, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                        TextField("", text: $currency)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                            .textCase(.uppercase)
                            .onChange(of: currency) { _, new in
                                let upper = new.uppercased()
                                if upper != new { currency = upper }
                            }
                    }
                }
                LabeledContent("Tip") {
                    HStack(spacing: 6) {
                        TextField("", value: $tipPercent, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                        Text("%").foregroundStyle(.secondary)
                        Slider(value: $tipPercent, in: 0...30, step: 1)
                            .frame(maxWidth: 200)
                    }
                }
                LabeledContent("Split between") {
                    HStack(spacing: 6) {
                        TextField("", value: $people, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                            .onChange(of: people) { _, new in
                                let clamped = min(max(new, 1), 50)
                                if clamped != new { people = clamped }
                            }
                        Stepper("", value: $people, in: 1...50)
                            .labelsHidden()
                        Text("people").foregroundStyle(.secondary)
                    }
                }
                Toggle("Round each share up to nearest \(currency) 5", isOn: $roundUp)
            }

            let tipAmount = bill * tipPercent / 100
            let total = bill + tipAmount
            let rawPerPerson = total / Double(max(people, 1))
            let perPerson = roundUp ? (rawPerPerson / 5.0).rounded(.up) * 5.0 : rawPerPerson
            let actualTotal = perPerson * Double(max(people, 1))

            Section("Result") {
                ResultRow(label: "Tip",
                          value: FinanceMath.money(tipAmount, code: currency),
                          sendable: String(format: "%.2f", tipAmount))
                ResultRow(label: "Total",
                          value: FinanceMath.money(roundUp ? actualTotal : total, code: currency),
                          sendable: String(format: "%.2f", roundUp ? actualTotal : total))
                ResultRow(label: "Per person",
                          value: FinanceMath.money(perPerson, code: currency),
                          sendable: String(format: "%.2f", perPerson),
                          emphasised: true)
                if roundUp && actualTotal != total {
                    Text("Rounded up to nearest \(FinanceMath.money(5, code: currency)) per person — actual tip becomes \(FinanceMath.money(actualTotal - bill, code: currency)).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(TallyTheme.background)
    }
}
