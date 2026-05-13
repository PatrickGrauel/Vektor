import SwiftUI
import Charts

struct LoanForm: View {
    @EnvironmentObject private var store: LoanStore

    @AppStorage("tally.finance.loan.principal")    private var principal: Double = 300_000
    @AppStorage("tally.finance.loan.rate")         private var ratePercent: Double = 5.5
    @AppStorage("tally.finance.loan.term")         private var termYears: Double = 30
    @AppStorage("tally.finance.loan.currency")     private var currency: String = "USD"
    @AppStorage("tally.finance.loan.extraMonthly") private var extraMonthly: Double = 0

    @State private var compareID: UUID? = nil
    @State private var showSaveSheet = false
    @State private var saveName: String = ""

    var body: some View {
        Form {
            // Scenario picker / save / delete
            scenarioBar

            Section("Loan parameters") {
                LabeledContent("Principal") {
                    HStack(spacing: 6) {
                        TextField("", value: $principal, format: .number)
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
                LabeledContent("Annual rate (%)") {
                    HStack(spacing: 6) {
                        TextField("", value: $ratePercent, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                        Slider(value: $ratePercent, in: 0...20, step: 0.05)
                            .frame(maxWidth: 220)
                    }
                }
                LabeledContent("Term (years)") {
                    HStack(spacing: 6) {
                        TextField("", value: $termYears, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                        Slider(value: $termYears, in: 1...40, step: 1)
                            .frame(maxWidth: 220)
                    }
                }
                LabeledContent("Extra payment / month") {
                    HStack(spacing: 6) {
                        TextField("", value: $extraMonthly, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                        Slider(value: $extraMonthly, in: 0...2000, step: 25)
                            .frame(maxWidth: 220)
                    }
                }
            }

            // Result block. Always shows the primary scenario; if a comparison
            // is selected, shows side-by-side columns with a diff row.
            resultSection
            extraSavingsSection
            chartSection
            comparisonSection
            amortizationSection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(TallyTheme.background)
        .sheet(isPresented: $showSaveSheet) {
            SaveScenarioSheet(
                title: "Save loan scenario",
                placeholder: "e.g. \"Current mortgage\"",
                initialName: saveName
            ) { name in
                store.add(SavedLoan(name: name,
                                    principal: principal,
                                    ratePercent: ratePercent,
                                    termYears: termYears,
                                    currency: currency,
                                    extraMonthly: extraMonthly))
                showSaveSheet = false
            } onCancel: { showSaveSheet = false }
        }
    }

    // MARK: - Subviews

    private var scenarioBar: some View {
        Section {
            HStack(spacing: 8) {
                Picker("Scenario", selection: Binding(
                    get: { selectedScenarioID },
                    set: { loadScenario($0) }
                )) {
                    Text("Custom").tag(UUID?.none)
                    ForEach(store.saved) { s in
                        Text("★ \(s.name)").tag(UUID?.some(s.id))
                    }
                }

                Button {
                    saveName = currentScenarioName
                    showSaveSheet = true
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }

                if let id = selectedScenarioID,
                   let scenario = store.saved.first(where: { $0.id == id }) {
                    Button(role: .destructive) {
                        store.remove(scenario.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help("Delete this saved scenario")
                }
            }
        }
    }

    @ViewBuilder
    private var resultSection: some View {
        let r = computed
        Section("Monthly payment") {
            ResultRow(label: "Monthly payment",
                      value: FinanceMath.money(r.monthlyPayment + extraMonthly, code: currency),
                      sendable: String(format: "%.2f", r.monthlyPayment + extraMonthly),
                      emphasised: true)
            ResultRow(label: "Base payment",
                      value: FinanceMath.money(r.monthlyPayment, code: currency),
                      sendable: String(format: "%.2f", r.monthlyPayment))
            ResultRow(label: "Total interest",
                      value: FinanceMath.money(r.totalInterest, code: currency),
                      sendable: String(format: "%.2f", r.totalInterest))
            ResultRow(label: "Total cost",
                      value: FinanceMath.money(r.totalCost, code: currency),
                      sendable: String(format: "%.2f", r.totalCost))
            ResultRow(label: "Paid off in",
                      value: FinanceMath.formatMonths(r.monthsPaid))
        }
    }

    @ViewBuilder
    private var extraSavingsSection: some View {
        if extraMonthly > 0 {
            let baseline = FinanceMath.loan(principal: principal,
                                            annualRatePercent: ratePercent,
                                            termYears: Int(termYears),
                                            extraMonthly: 0)
            let withExtra = computed
            let monthsSaved = baseline.monthsPaid - withExtra.monthsPaid
            let interestSaved = baseline.totalInterest - withExtra.totalInterest

            Section {
                ResultRow(label: "Time saved",
                          value: FinanceMath.formatMonths(monthsSaved),
                          emphasised: true)
                ResultRow(label: "Interest saved",
                          value: FinanceMath.money(interestSaved, code: currency),
                          sendable: String(format: "%.2f", interestSaved),
                          emphasised: true)
            } header: {
                Text("Prepayment savings")
            } footer: {
                Text("Compared to paying only the base \(FinanceMath.money(baseline.monthlyPayment, code: currency)) each month.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var chartSection: some View {
        Section("Principal vs interest over time") {
            Chart(monthlyChartData(), id: \.month) { row in
                AreaMark(
                    x: .value("Month", row.month),
                    y: .value("Principal", row.principalCum)
                )
                .foregroundStyle(by: .value("Series", "Principal"))
                .interpolationMethod(.monotone)

                AreaMark(
                    x: .value("Month", row.month),
                    y: .value("Interest", row.interestCum)
                )
                .foregroundStyle(by: .value("Series", "Interest"))
                .interpolationMethod(.monotone)
            }
            .chartLegend(position: .bottom, alignment: .leading)
            .chartForegroundStyleScale([
                "Principal": TallyTheme.accent.opacity(0.6),
                "Interest":  TallyTheme.statusBad.opacity(0.3)
            ])
            .frame(height: 180)
        }
    }

    @ViewBuilder
    private var comparisonSection: some View {
        if let scenario = store.saved.first(where: { $0.id == compareID }) {
            let other = FinanceMath.loan(principal: scenario.principal,
                                         annualRatePercent: scenario.ratePercent,
                                         termYears: Int(scenario.termYears),
                                         extraMonthly: scenario.extraMonthly)
            let here = computed

            Section {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        Text("").gridColumnAlignment(.leading)
                        Text("Current").font(.caption).foregroundStyle(.secondary)
                        Text("★ \(scenario.name)").font(.caption).foregroundStyle(.secondary)
                        Text("Difference").font(.caption).foregroundStyle(.secondary)
                    }
                    Divider().gridCellColumns(4)
                    diffRow(label: "Monthly", a: here.monthlyPayment + extraMonthly,
                            b: other.monthlyPayment + scenario.extraMonthly,
                            currency: currency)
                    diffRow(label: "Total interest", a: here.totalInterest,
                            b: other.totalInterest, currency: currency)
                    diffRow(label: "Total cost", a: here.totalCost,
                            b: other.totalCost, currency: currency)
                    GridRow {
                        Text("Paid off in")
                        Text(FinanceMath.formatMonths(here.monthsPaid))
                            .font(.system(.body, design: .monospaced))
                        Text(FinanceMath.formatMonths(other.monthsPaid))
                            .font(.system(.body, design: .monospaced))
                        Text(monthsDiff(a: here.monthsPaid, b: other.monthsPaid))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(here.monthsPaid < other.monthsPaid ? .green : .red)
                    }
                }
            } header: {
                HStack {
                    Text("Compare with")
                    Picker("", selection: $compareID) {
                        Text("None").tag(UUID?.none)
                        ForEach(store.saved) { s in
                            Text("★ \(s.name)").tag(UUID?.some(s.id))
                        }
                    }
                    .labelsHidden()
                }
            }
        } else if !store.saved.isEmpty {
            Section {
                Picker("Compare with", selection: $compareID) {
                    Text("None").tag(UUID?.none)
                    ForEach(store.saved) { s in
                        Text("★ \(s.name)").tag(UUID?.some(s.id))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func diffRow(label: String, a: Double, b: Double, currency: String) -> some View {
        GridRow {
            Text(label)
            Text(FinanceMath.money(a, code: currency))
                .font(.system(.body, design: .monospaced))
            Text(FinanceMath.money(b, code: currency))
                .font(.system(.body, design: .monospaced))
            let delta = a - b
            Text((delta >= 0 ? "+" : "") + FinanceMath.money(delta, code: currency))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(delta <= 0 ? .green : .red)
        }
    }

    private func monthsDiff(a: Int, b: Int) -> String {
        let d = a - b
        let prefix = d >= 0 ? "+" : "−"
        return prefix + FinanceMath.formatMonths(abs(d))
    }

    private var amortizationSection: some View {
        let rows = previewRows(computed.amortization)
        return Section {
            Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("Month").font(.caption).foregroundStyle(.secondary)
                    Text("Interest").font(.caption).foregroundStyle(.secondary)
                    Text("Principal").font(.caption).foregroundStyle(.secondary)
                    Text("Balance").font(.caption).foregroundStyle(.secondary)
                }
                Divider().gridCellColumns(4)
                ForEach(rows, id: \.month) { row in
                    GridRow {
                        Text("\(row.month)")
                            .font(.system(.body, design: .monospaced))
                        Text(FinanceMath.money(row.interest, code: currency))
                            .font(.system(.body, design: .monospaced))
                        Text(FinanceMath.money(row.principal, code: currency))
                            .font(.system(.body, design: .monospaced))
                        Text(FinanceMath.money(row.balance, code: currency))
                            .font(.system(.body, design: .monospaced))
                    }
                }
            }
        } header: {
            Text("Amortization (first year & last year)")
        } footer: {
            Text("Each row is a monthly payment showing interest vs principal split and remaining balance.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Data

    private var computed: FinanceMath.LoanResult {
        FinanceMath.loan(principal: principal,
                         annualRatePercent: ratePercent,
                         termYears: Int(termYears),
                         extraMonthly: extraMonthly)
    }

    private func previewRows(_ rows: [FinanceMath.AmortizationRow]) -> [FinanceMath.AmortizationRow] {
        guard rows.count > 24 else { return rows }
        return Array(rows.prefix(12)) + Array(rows.suffix(12))
    }

    private struct ChartRow {
        let month: Int
        let principalCum: Double
        let interestCum: Double
    }

    private func monthlyChartData() -> [ChartRow] {
        var principalCum: Double = 0
        var interestCum: Double = 0
        return computed.amortization.map { row in
            principalCum += row.principal
            interestCum  += row.interest
            return ChartRow(month: row.month,
                            principalCum: principalCum,
                            interestCum: interestCum)
        }
    }

    // MARK: - Scenarios

    private var selectedScenarioID: UUID? {
        store.saved.first {
            $0.principal == principal && $0.ratePercent == ratePercent &&
            $0.termYears == termYears && $0.currency == currency &&
            $0.extraMonthly == extraMonthly
        }?.id
    }

    private var currentScenarioName: String {
        selectedScenarioID.flatMap { id in
            store.saved.first(where: { $0.id == id })?.name
        } ?? ""
    }

    private func loadScenario(_ id: UUID?) {
        guard let id, let s = store.saved.first(where: { $0.id == id }) else { return }
        principal = s.principal
        ratePercent = s.ratePercent
        termYears = s.termYears
        currency = s.currency
        extraMonthly = s.extraMonthly
    }
}
