import SwiftUI
import Charts

struct RealEstateForm: View {
    @EnvironmentObject private var store: RealEstateStore

    // Naming
    @AppStorage("tally.finance.re.address")  private var address: String = ""

    // Property
    @AppStorage("tally.finance.re.price")    private var purchasePrice: Double = 500_000
    @AppStorage("tally.finance.re.closing")  private var closingCostsPercent: Double = 3.0
    @AppStorage("tally.finance.re.currency") private var currency: String = "USD"
    // Financing
    @AppStorage("tally.finance.re.downPct")  private var downPaymentPercent: Double = 25
    @AppStorage("tally.finance.re.rate")     private var mortgageRatePercent: Double = 6.5
    @AppStorage("tally.finance.re.term")     private var loanTermYears: Double = 30
    // Income
    @AppStorage("tally.finance.re.rent")     private var monthlyRent: Double = 3_500
    @AppStorage("tally.finance.re.vacancy")  private var vacancyPercent: Double = 5
    @AppStorage("tally.finance.re.other")    private var otherMonthlyIncome: Double = 0
    @AppStorage("tally.finance.re.rentGrow") private var annualRentGrowthPercent: Double = 3
    // OpEx
    @AppStorage("tally.finance.re.tax")      private var propertyTaxAnnual: Double = 4_500
    @AppStorage("tally.finance.re.ins")      private var insuranceAnnual: Double = 1_200
    @AppStorage("tally.finance.re.maint")    private var maintenancePercentOfRent: Double = 8
    @AppStorage("tally.finance.re.mgmt")     private var propertyMgmtPercentOfRent: Double = 8
    @AppStorage("tally.finance.re.hoa")      private var hoaMonthly: Double = 0
    @AppStorage("tally.finance.re.capex")    private var capExPercentOfRent: Double = 5
    @AppStorage("tally.finance.re.util")     private var utilitiesAnnual: Double = 0
    // Hold + exit
    @AppStorage("tally.finance.re.appr")     private var appreciationPercent: Double = 3
    @AppStorage("tally.finance.re.hold")     private var holdYears: Double = 10
    @AppStorage("tally.finance.re.sellPct")  private var sellingCostsPercent: Double = 6

    @State private var compareID: UUID? = nil
    @State private var showSaveSheet = false
    @State private var saveName: String = ""

    var body: some View {
        Form {
            scenarioBar
            metricsDashboard

            // Sticky-ish dashboard up top, then the long input list and
            // the deep dives. Architectural note: keeping the inputs below
            // the dashboard is intentional — pros tweak knobs and watch
            // the metrics react, not the other way around.

            propertySection
            financingSection
            incomeSection
            operatingSection
            holdSection

            year1PnLSection
            cashFlowChartSection
            equityBuildupSection
            saleSection
            sensitivitySection
            comparisonSection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(TallyTheme.background)
        .sheet(isPresented: $showSaveSheet) {
            SaveScenarioSheet(
                title: "Save deal",
                placeholder: "e.g. \"123 Maple St duplex\"",
                initialName: saveName
            ) { name in
                let deal = SavedRealEstateDeal(
                    name: name, address: address, currency: currency,
                    purchasePrice: purchasePrice,
                    closingCostsPercent: closingCostsPercent,
                    downPaymentPercent: downPaymentPercent,
                    mortgageRatePercent: mortgageRatePercent,
                    loanTermYears: loanTermYears,
                    monthlyRent: monthlyRent,
                    vacancyPercent: vacancyPercent,
                    otherMonthlyIncome: otherMonthlyIncome,
                    annualRentGrowthPercent: annualRentGrowthPercent,
                    propertyTaxAnnual: propertyTaxAnnual,
                    insuranceAnnual: insuranceAnnual,
                    maintenancePercentOfRent: maintenancePercentOfRent,
                    propertyMgmtPercentOfRent: propertyMgmtPercentOfRent,
                    hoaMonthly: hoaMonthly,
                    capExPercentOfRent: capExPercentOfRent,
                    utilitiesAnnual: utilitiesAnnual,
                    appreciationPercent: appreciationPercent,
                    holdYears: Int(holdYears),
                    sellingCostsPercent: sellingCostsPercent
                )
                store.add(deal)
                showSaveSheet = false
            } onCancel: { showSaveSheet = false }
        }
    }

    // MARK: - Top: scenario bar + dashboard

    @ViewBuilder
    private var scenarioBar: some View {
        Section {
            HStack(spacing: 8) {
                Picker("Deal", selection: Binding(
                    get: { selectedID },
                    set: { loadScenario($0) }
                )) {
                    Text("New deal").tag(UUID?.none)
                    ForEach(store.saved) { d in
                        Text("★ \(d.name)").tag(UUID?.some(d.id))
                    }
                }

                Button {
                    saveName = currentName.isEmpty ? "Deal" : currentName
                    showSaveSheet = true
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }

                if let id = selectedID,
                   let d = store.saved.first(where: { $0.id == id }) {
                    Button(role: .destructive) {
                        store.remove(d.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help("Delete this saved deal")
                }
            }
            if !address.isEmpty || selectedID != nil {
                TextField("Address / notes", text: $address)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    @ViewBuilder
    private var metricsDashboard: some View {
        let r = result
        Section {
            // One unified Grid so column widths and row baselines align
            // across the whole dashboard, instead of two stacked grids
            // that drifted apart vertically.
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow {
                    metricBox(title: "Monthly cash flow",
                              value: FinanceMath.money(r.y1CashFlow / 12, code: currency),
                              level: status(forCashFlow: r.y1CashFlow),
                              help: "Year-1 cash flow before tax, divided by 12.")
                    metricBox(title: "Cap rate",
                              value: String(format: "%.2f%%", r.capRate),
                              level: status(forCapRate: r.capRate),
                              help: "NOI ÷ purchase price. Rules of thumb: ≥6% strong, 4–6% market, <4% thin.")
                    metricBox(title: "Cash on cash",
                              value: String(format: "%.2f%%", r.cashOnCashReturn),
                              level: status(forCoC: r.cashOnCashReturn),
                              help: "Year-1 cash flow ÷ cash invested. Pros target ≥8%.")
                }
                GridRow {
                    metricBox(title: "DSCR",
                              value: String(format: "%.2f", r.dscr),
                              level: status(forDSCR: r.dscr),
                              help: "NOI ÷ debt service. Lenders typically want ≥1.20.")
                    metricBox(title: "GRM",
                              value: String(format: "%.1f", r.grm),
                              level: .neutral,
                              help: "Gross Rent Multiplier = price ÷ annual gross rent. Lower is cheaper.")
                    metricBox(title: "Rent / price",
                              value: String(format: "%.2f%%", r.rentRatio),
                              subtitle: r.rentRatio >= 1 ? "Passes 1% rule" : "Below 1% rule",
                              level: status(forRentRatio: r.rentRatio),
                              help: "Monthly rent as % of price. The classic 1% rule: rent ≥ 1% of price.")
                }
                if let irr = r.irr {
                    GridRow {
                        metricBox(title: "IRR (\(Int(holdYears))-yr hold)",
                                  value: String(format: "%.2f%%", irr),
                                  level: status(forIRR: irr),
                                  help: "Annualised return on cash invested over the hold period.")
                        metricBox(title: "Equity multiple",
                                  value: String(format: "%.2fx", r.equityMultiple),
                                  level: r.equityMultiple >= 2 ? .good : .neutral,
                                  help: "Total cash returned ÷ cash invested. ≥2x is a healthy hold.")
                        metricBox(title: "Total return",
                                  value: FinanceMath.money(r.totalReturn, code: currency),
                                  level: r.totalReturn >= 0 ? .good : .bad,
                                  help: "Cash flow + cash from sale − cash invested.")
                    }
                }
            }
        } header: {
            Text("Key metrics")
        } footer: {
            Text("Hover any tile for its definition. Status colours are paired with icons so the signal isn't colour-only.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func metricBox(title: String,
                           value: String,
                           subtitle: String? = nil,
                           level: StatusLevel,
                           help: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                StatusBadge(level: level)
                    .font(.caption2)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.title3.bold())
                .foregroundStyle(level.colour)
                .monospacedDigit()
            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .help(help)
    }

    // MARK: - Inputs

    private var propertySection: some View {
        Section("Property") {
            LabeledContent("Purchase price") {
                HStack(spacing: 6) {
                    TextField("", value: $purchasePrice, format: .number)
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
            slider("Closing costs (%)", value: $closingCostsPercent, range: 0...10, step: 0.1)
        }
    }

    private var financingSection: some View {
        Section {
            slider("Down payment (%)", value: $downPaymentPercent, range: 0...100, step: 1)
            LabeledContent("Loan amount") {
                Text(FinanceMath.money(result.loanAmount, code: currency))
                    .foregroundStyle(.secondary)
            }
            slider("Mortgage rate (%)", value: $mortgageRatePercent, range: 0...15, step: 0.05)
            slider("Loan term (years)", value: $loanTermYears, range: 1...40, step: 1)
            LabeledContent("Monthly P&I") {
                Text(FinanceMath.money(result.monthlyMortgagePayment, code: currency))
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Financing")
        } footer: {
            Text("Cash invested = down payment + closing costs = \(FinanceMath.money(result.cashInvested, code: currency))")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var incomeSection: some View {
        Section("Rental income") {
            LabeledContent("Monthly rent") {
                HStack(spacing: 6) {
                    TextField("", value: $monthlyRent, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                    Text(currency).foregroundStyle(.secondary)
                }
            }
            slider("Vacancy (%)", value: $vacancyPercent, range: 0...30, step: 0.5)
            LabeledContent("Other monthly income") {
                HStack(spacing: 6) {
                    TextField("", value: $otherMonthlyIncome, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    Text(currency).foregroundStyle(.secondary)
                }
            }
            slider("Annual rent growth (%)", value: $annualRentGrowthPercent, range: 0...10, step: 0.1)
        }
    }

    private var operatingSection: some View {
        Section {
            LabeledContent("Property tax / yr") {
                HStack(spacing: 6) {
                    TextField("", value: $propertyTaxAnnual, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                    Text(currency).foregroundStyle(.secondary)
                }
            }
            LabeledContent("Insurance / yr") {
                HStack(spacing: 6) {
                    TextField("", value: $insuranceAnnual, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                    Text(currency).foregroundStyle(.secondary)
                }
            }
            slider("Maintenance (% of rent)", value: $maintenancePercentOfRent, range: 0...30, step: 0.5)
            slider("Property mgmt (% of rent)", value: $propertyMgmtPercentOfRent, range: 0...15, step: 0.5)
            LabeledContent("HOA / month") {
                HStack(spacing: 6) {
                    TextField("", value: $hoaMonthly, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                    Text(currency).foregroundStyle(.secondary)
                }
            }
            slider("CapEx reserve (% of rent)", value: $capExPercentOfRent, range: 0...20, step: 0.5)
            LabeledContent("Utilities / yr (landlord-paid)") {
                HStack(spacing: 6) {
                    TextField("", value: $utilitiesAnnual, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                    Text(currency).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Operating expenses")
        } footer: {
            Text("Year-1 OpEx total: \(FinanceMath.money(result.y1OperatingExpenses, code: currency)) · OER \(String(format: "%.1f", result.y1OperatingExpenseRatio))% (35–45% is typical for residential).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var holdSection: some View {
        Section("Hold period & exit") {
            slider("Appreciation (% / yr)", value: $appreciationPercent, range: 0...10, step: 0.1)
            slider("Hold years", value: $holdYears, range: 1...30, step: 1)
            slider("Selling costs (% of sale)", value: $sellingCostsPercent, range: 0...10, step: 0.5)
        }
    }

    // MARK: - Outputs

    private var year1PnLSection: some View {
        let r = result
        return Section {
            ResultRow(label: "Gross scheduled rent",
                      value: FinanceMath.money(r.y1GrossRent, code: currency),
                      sendable: String(format: "%.2f", r.y1GrossRent))
            ResultRow(label: "Vacancy loss",
                      value: "(\(FinanceMath.money(r.y1VacancyLoss, code: currency)))",
                      sendable: String(format: "%.2f", -r.y1VacancyLoss))
            if r.y1OtherIncome > 0 {
                ResultRow(label: "Other income",
                          value: FinanceMath.money(r.y1OtherIncome, code: currency),
                          sendable: String(format: "%.2f", r.y1OtherIncome))
            }
            ResultRow(label: "Effective gross income",
                      value: FinanceMath.money(r.y1EffectiveGrossIncome, code: currency),
                      sendable: String(format: "%.2f", r.y1EffectiveGrossIncome))
            ResultRow(label: "Operating expenses",
                      value: "(\(FinanceMath.money(r.y1OperatingExpenses, code: currency)))",
                      sendable: String(format: "%.2f", -r.y1OperatingExpenses))
            ResultRow(label: "NOI",
                      value: FinanceMath.money(r.y1NOI, code: currency),
                      sendable: String(format: "%.2f", r.y1NOI),
                      emphasised: true)
            ResultRow(label: "Debt service",
                      value: "(\(FinanceMath.money(r.y1DebtService, code: currency)))",
                      sendable: String(format: "%.2f", -r.y1DebtService))
            ResultRow(label: "Cash flow before tax",
                      value: FinanceMath.money(r.y1CashFlow, code: currency),
                      sendable: String(format: "%.2f", r.y1CashFlow),
                      emphasised: true)
        } header: {
            Text("Year-1 P&L")
        } footer: {
            Text("Cash flow before tax = NOI − annual debt service (P&I only). Excludes income tax effects and depreciation; consult an accountant for after-tax modelling.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var cashFlowChartSection: some View {
        let r = result
        return Section("Cash flow over hold period") {
            Chart {
                ForEach(r.yearByYear, id: \.year) { yr in
                    BarMark(
                        x: .value("Year", yr.year),
                        y: .value("Cash flow", yr.cashFlow)
                    )
                    .foregroundStyle(yr.cashFlow >= 0
                        ? TallyTheme.accent.opacity(0.7)
                        : TallyTheme.statusBad.opacity(0.7))
                }
            }
            .frame(height: 160)
        }
    }

    private var equityBuildupSection: some View {
        let r = result
        return Section {
            Chart {
                ForEach(r.yearByYear, id: \.year) { yr in
                    AreaMark(
                        x: .value("Year", yr.year),
                        y: .value("Equity", yr.equity),
                        series: .value("Series", "Total equity (value − loan)")
                    )
                    .foregroundStyle(TallyTheme.accent.opacity(0.30))
                    .interpolationMethod(.monotone)
                    LineMark(
                        x: .value("Year", yr.year),
                        y: .value("Equity", yr.equity),
                        series: .value("Series", "Total equity (value − loan)")
                    )
                    .foregroundStyle(TallyTheme.accent)
                    .interpolationMethod(.monotone)
                    LineMark(
                        x: .value("Year", yr.year),
                        y: .value("Cumulative cash flow", yr.cumulativeCashFlow),
                        series: .value("Series", "Cumulative cash flow")
                    )
                    .foregroundStyle(TallyTheme.statusGood)
                    .interpolationMethod(.monotone)
                }
            }
            .chartLegend(position: .bottom, alignment: .leading)
            .frame(height: 200)
        } header: {
            Text("Equity build-up")
        } footer: {
            Text("Equity = property value at year-end minus remaining loan balance. Grows from appreciation and principal pay-down over time.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var saleSection: some View {
        let r = result
        return Section {
            ResultRow(label: "Property value at sale",
                      value: FinanceMath.money(r.propertyValueAtSale, code: currency),
                      sendable: String(format: "%.2f", r.propertyValueAtSale))
            ResultRow(label: "Selling costs",
                      value: "(\(FinanceMath.money(r.propertyValueAtSale - r.netSaleProceeds, code: currency)))",
                      sendable: String(format: "%.2f", -(r.propertyValueAtSale - r.netSaleProceeds)))
            ResultRow(label: "Loan balance at sale",
                      value: "(\(FinanceMath.money(r.loanBalanceAtSale, code: currency)))",
                      sendable: String(format: "%.2f", -r.loanBalanceAtSale))
            ResultRow(label: "Cash from sale",
                      value: FinanceMath.money(r.cashFromSale, code: currency),
                      sendable: String(format: "%.2f", r.cashFromSale),
                      emphasised: true)
            ResultRow(label: "Total cash flow over hold",
                      value: FinanceMath.money(r.totalCashFlow, code: currency),
                      sendable: String(format: "%.2f", r.totalCashFlow))
            ResultRow(label: "Total return",
                      value: FinanceMath.money(r.totalReturn, code: currency),
                      sendable: String(format: "%.2f", r.totalReturn),
                      emphasised: true)
        } header: {
            Text("Exit (year \(Int(holdYears)))")
        } footer: {
            Text("Cash from sale = net proceeds − remaining loan. Total return = total cash flow + cash from sale − cash invested.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var sensitivitySection: some View {
        let r = result
        return Section {
            ResultRow(label: "Break-even rent",
                      value: FinanceMath.money(r.breakEvenMonthlyRent, code: currency) + " / mo",
                      sendable: String(format: "%.2f", r.breakEvenMonthlyRent))
            ResultRow(label: "Break-even occupancy",
                      value: String(format: "%.1f%%", r.breakEvenOccupancyPercent),
                      sendable: String(format: "%.2f", r.breakEvenOccupancyPercent))
            let buffer = max(monthlyRent - r.breakEvenMonthlyRent, 0)
            ResultRow(label: "Rent safety margin",
                      value: FinanceMath.money(buffer, code: currency) + " / mo",
                      sendable: String(format: "%.2f", buffer))
        } header: {
            Text("Sensitivity")
        } footer: {
            Text("Break-even rent: the monthly rent at which year-1 cash flow is zero. Break-even occupancy: the occupancy rate at which year-1 cash flow is zero, holding rent fixed.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var comparisonSection: some View {
        if let other = store.saved.first(where: { $0.id == compareID }) {
            let otherResult = RealEstateMath.analyze(toInputs(other))
            let here = result
            Section {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        Text("").gridColumnAlignment(.leading)
                        Text("Current").font(.caption).foregroundStyle(.secondary)
                        Text("★ \(other.name)").font(.caption).foregroundStyle(.secondary)
                        Text("Difference").font(.caption).foregroundStyle(.secondary)
                    }
                    Divider().gridCellColumns(4)
                    diffMoneyRow(label: "Monthly cash flow",
                                 a: here.y1CashFlow / 12,
                                 b: otherResult.y1CashFlow / 12)
                    diffPctRow(label: "Cap rate", a: here.capRate, b: otherResult.capRate)
                    diffPctRow(label: "Cash on cash", a: here.cashOnCashReturn, b: otherResult.cashOnCashReturn)
                    diffRatioRow(label: "DSCR", a: here.dscr, b: otherResult.dscr)
                    if let aIRR = here.irr, let bIRR = otherResult.irr {
                        diffPctRow(label: "IRR", a: aIRR, b: bIRR)
                    }
                    diffMoneyRow(label: "Total return",
                                 a: here.totalReturn,
                                 b: otherResult.totalReturn)
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

    // MARK: - Helpers

    private func slider(_ title: String,
                        value: Binding<Double>,
                        range: ClosedRange<Double>,
                        step: Double) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                // Use ClampedNumericField so typing 999 into a 0–20 rate
                // slider can't propagate insane values into the math.
                ClampedNumericField(value: value, range: range, width: 80)
                Slider(value: value, in: range, step: step)
                    .frame(maxWidth: 220)
            }
        }
    }

    private func diffMoneyRow(label: String, a: Double, b: Double) -> some View {
        GridRow {
            Text(label)
            Text(FinanceMath.money(a, code: currency)).font(.system(.body, design: .monospaced))
            Text(FinanceMath.money(b, code: currency)).font(.system(.body, design: .monospaced))
            let delta = a - b
            Text((delta >= 0 ? "+" : "") + FinanceMath.money(delta, code: currency))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(delta >= 0 ? .green : .red)
        }
    }

    private func diffPctRow(label: String, a: Double, b: Double) -> some View {
        GridRow {
            Text(label)
            Text(String(format: "%.2f%%", a)).font(.system(.body, design: .monospaced))
            Text(String(format: "%.2f%%", b)).font(.system(.body, design: .monospaced))
            let delta = a - b
            Text(String(format: "%@%.2f%%", delta >= 0 ? "+" : "−", abs(delta)))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(delta >= 0 ? .green : .red)
        }
    }

    private func diffRatioRow(label: String, a: Double, b: Double) -> some View {
        GridRow {
            Text(label)
            Text(String(format: "%.2f", a)).font(.system(.body, design: .monospaced))
            Text(String(format: "%.2f", b)).font(.system(.body, design: .monospaced))
            let delta = a - b
            Text(String(format: "%@%.2f", delta >= 0 ? "+" : "−", abs(delta)))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(delta >= 0 ? .green : .red)
        }
    }

    // Threshold-based status cues (rules of thumb, conservative). All
    // route through the shared `StatusLevel` so the colour scale is
    // unified across the app and pairs with an icon — never colour-only.
    private func status(forCashFlow v: Double) -> StatusLevel {
        v >= 0 ? .good : .bad
    }
    private func status(forCapRate v: Double) -> StatusLevel {
        if v >= 6 { return .good }
        if v >= 4 { return .neutral }
        return .caution
    }
    private func status(forCoC v: Double) -> StatusLevel {
        if v >= 8 { return .good }
        if v >= 4 { return .neutral }
        return .caution
    }
    private func status(forDSCR v: Double) -> StatusLevel {
        if v >= 1.25 { return .good }
        if v >= 1.00 { return .caution }
        return .bad
    }
    private func status(forIRR v: Double) -> StatusLevel {
        if v >= 12 { return .good }
        if v >= 8  { return .neutral }
        return .caution
    }
    private func status(forRentRatio v: Double) -> StatusLevel {
        if v >= 1.0  { return .good }
        if v >= 0.85 { return .neutral }
        return .caution
    }

    // MARK: - Data binding

    private var inputs: RealEstateMath.Inputs {
        RealEstateMath.Inputs(
            purchasePrice: purchasePrice,
            closingCostsPercent: closingCostsPercent,
            downPaymentPercent: downPaymentPercent,
            mortgageRatePercent: mortgageRatePercent,
            loanTermYears: loanTermYears,
            monthlyRent: monthlyRent,
            vacancyPercent: vacancyPercent,
            otherMonthlyIncome: otherMonthlyIncome,
            annualRentGrowthPercent: annualRentGrowthPercent,
            propertyTaxAnnual: propertyTaxAnnual,
            insuranceAnnual: insuranceAnnual,
            maintenancePercentOfRent: maintenancePercentOfRent,
            propertyMgmtPercentOfRent: propertyMgmtPercentOfRent,
            hoaMonthly: hoaMonthly,
            capExPercentOfRent: capExPercentOfRent,
            utilitiesAnnual: utilitiesAnnual,
            appreciationPercent: appreciationPercent,
            holdYears: Int(holdYears),
            sellingCostsPercent: sellingCostsPercent
        )
    }

    private var result: RealEstateMath.Result {
        RealEstateMath.analyze(inputs)
    }

    private func toInputs(_ s: SavedRealEstateDeal) -> RealEstateMath.Inputs {
        RealEstateMath.Inputs(
            purchasePrice: s.purchasePrice,
            closingCostsPercent: s.closingCostsPercent,
            downPaymentPercent: s.downPaymentPercent,
            mortgageRatePercent: s.mortgageRatePercent,
            loanTermYears: s.loanTermYears,
            monthlyRent: s.monthlyRent,
            vacancyPercent: s.vacancyPercent,
            otherMonthlyIncome: s.otherMonthlyIncome,
            annualRentGrowthPercent: s.annualRentGrowthPercent,
            propertyTaxAnnual: s.propertyTaxAnnual,
            insuranceAnnual: s.insuranceAnnual,
            maintenancePercentOfRent: s.maintenancePercentOfRent,
            propertyMgmtPercentOfRent: s.propertyMgmtPercentOfRent,
            hoaMonthly: s.hoaMonthly,
            capExPercentOfRent: s.capExPercentOfRent,
            utilitiesAnnual: s.utilitiesAnnual,
            appreciationPercent: s.appreciationPercent,
            holdYears: s.holdYears,
            sellingCostsPercent: s.sellingCostsPercent
        )
    }

    private var selectedID: UUID? {
        store.saved.first { matches($0) }?.id
    }
    private var currentName: String {
        selectedID.flatMap { id in store.saved.first(where: { $0.id == id })?.name } ?? ""
    }
    private func matches(_ s: SavedRealEstateDeal) -> Bool {
        // Loose equality on the numeric inputs — used to highlight the
        // active scenario in the picker.
        return s.purchasePrice == purchasePrice
            && s.downPaymentPercent == downPaymentPercent
            && s.mortgageRatePercent == mortgageRatePercent
            && s.loanTermYears == loanTermYears
            && s.monthlyRent == monthlyRent
            && s.holdYears == Int(holdYears)
    }
    private func loadScenario(_ id: UUID?) {
        guard let id, let s = store.saved.first(where: { $0.id == id }) else { return }
        address = s.address
        currency = s.currency
        purchasePrice = s.purchasePrice
        closingCostsPercent = s.closingCostsPercent
        downPaymentPercent = s.downPaymentPercent
        mortgageRatePercent = s.mortgageRatePercent
        loanTermYears = s.loanTermYears
        monthlyRent = s.monthlyRent
        vacancyPercent = s.vacancyPercent
        otherMonthlyIncome = s.otherMonthlyIncome
        annualRentGrowthPercent = s.annualRentGrowthPercent
        propertyTaxAnnual = s.propertyTaxAnnual
        insuranceAnnual = s.insuranceAnnual
        maintenancePercentOfRent = s.maintenancePercentOfRent
        propertyMgmtPercentOfRent = s.propertyMgmtPercentOfRent
        hoaMonthly = s.hoaMonthly
        capExPercentOfRent = s.capExPercentOfRent
        utilitiesAnnual = s.utilitiesAnnual
        appreciationPercent = s.appreciationPercent
        holdYears = Double(s.holdYears)
        sellingCostsPercent = s.sellingCostsPercent
    }
}
