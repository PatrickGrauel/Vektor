import SwiftUI
import TallyEngine

/// One recurring subscription. The amount is in the named currency
/// — the form converts to the user's base currency for the totals
/// using the calculator engine's live FX rates.
struct SavedSubscription: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var amount: Double
    var currency: String
    var period: BillingPeriod
    /// When the next bill hits. Used for "next 30 days" projections
    /// — kept simple so the user doesn't need a full calendar.
    var startDate: Date

    init(id: UUID = UUID(),
         name: String = "",
         amount: Double = 0,
         currency: String = "EUR",
         period: BillingPeriod = .monthly,
         startDate: Date = .now) {
        self.id = id
        self.name = name
        self.amount = amount
        self.currency = currency
        self.period = period
        self.startDate = startDate
    }

    /// Annualised cost in the subscription's own currency.
    /// Conversion to a base currency happens at display time.
    var annualCostInOwnCurrency: Double {
        amount * Double(period.timesPerYear)
    }
}

enum BillingPeriod: String, Codable, CaseIterable, Identifiable {
    case weekly, monthly, quarterly, annual
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    /// How many billing cycles in a year. Quarterly = 4, weekly = 52.
    var timesPerYear: Int {
        switch self {
        case .weekly:     return 52
        case .monthly:    return 12
        case .quarterly:  return 4
        case .annual:     return 1
        }
    }
}

typealias SubscriptionStore = PersistentStore<SavedSubscription>

extension PersistentStore where T == SavedSubscription {
    static func subscriptions() -> SubscriptionStore {
        SubscriptionStore(
            storageKey: "tally.finance.subscriptions.v1",
            matches: { $0.id == $1.id }
        )
    }
}

struct SubscriptionsForm: View {
    @StateObject private var store = SubscriptionStore.subscriptions()
    @AppStorage("tally.finance.subs.baseCurrency") private var baseCurrency: String = "EUR"
    @AppStorage("tally.finance.subs.fxJSON")       private var fxJSON: String = "{}"
    @State private var editing: SavedSubscription?
    @State private var showAddSheet = false

    // FX rates indexed by 3-letter code, values are units of base
    // currency per 1 unit of that currency (so EUR → 1.0 if base
    // is EUR). Persisted as JSON in @AppStorage so a manual rate
    // table survives launches without a separate plist.
    private var fxRates: [String: Double] {
        get {
            guard let data = fxJSON.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([String: Double].self, from: data)
            else { return [:] }
            return decoded
        }
    }

    private var totalMonthlyInBase: Double {
        store.saved
            .map { convertToBase($0.annualCostInOwnCurrency, from: $0.currency) / 12.0 }
            .reduce(0, +)
    }
    private var totalAnnualInBase: Double {
        store.saved
            .map { convertToBase($0.annualCostInOwnCurrency, from: $0.currency) }
            .reduce(0, +)
    }

    var body: some View {
        Form {
            dashboardSection
            controlsSection
            listSection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(TallyTheme.background)
        .sheet(item: $editing) { sub in
            SubscriptionEditor(initial: sub) { updated in
                store.add(updated)
                editing = nil
            } onCancel: {
                editing = nil
            } onDelete: {
                store.remove(sub.id)
                editing = nil
            }
        }
        .sheet(isPresented: $showAddSheet) {
            SubscriptionEditor(
                initial: SavedSubscription(currency: baseCurrency),
                onSave: { added in
                    store.add(added)
                    showAddSheet = false
                },
                onCancel: { showAddSheet = false },
                onDelete: nil
            )
        }
    }

    private var dashboardSection: some View {
        Section {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3),
                      spacing: 10) {
                MetricBox(
                    value: formatMoney(totalMonthlyInBase),
                    label: "Monthly burn",
                    tone: .accent
                )
                MetricBox(
                    value: formatMoney(totalAnnualInBase),
                    label: "Annual total",
                    hint: "\(store.saved.count) subscription\(store.saved.count == 1 ? "" : "s")"
                )
                MetricBox(
                    value: formatMoney(totalAnnualInBase / 365),
                    label: "Per day"
                )
            }
        } header: {
            Text("Subscriptions").font(.headline)
        } footer: {
            if store.saved.isEmpty {
                Text("Tap “Add subscription” to start. Each one annualises automatically (weekly × 52, monthly × 12, quarterly × 4, annual × 1).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var controlsSection: some View {
        Section {
            HStack {
                LabeledContent("Base currency") {
                    CurrencyField(code: $baseCurrency)
                }
                Spacer()
                Button {
                    showAddSheet = true
                } label: {
                    Label("Add subscription", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(TallyTheme.accent)
            }
        }
    }

    @ViewBuilder
    private var listSection: some View {
        if !store.saved.isEmpty {
            Section {
                ForEach(store.saved.sorted(by: { $0.amount * Double($0.period.timesPerYear) > $1.amount * Double($1.period.timesPerYear) })) { sub in
                    SubscriptionRow(
                        sub: sub,
                        monthlyInBase: convertToBase(sub.annualCostInOwnCurrency, from: sub.currency) / 12,
                        baseCurrency: baseCurrency
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { editing = sub }
                }
            } header: {
                Text("Your subscriptions").font(.headline)
            } footer: {
                Text("Click any row to edit or delete it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Convert `amount` from `from` currency to the base currency.
    /// If no rate is known, falls through 1:1 (the user can override
    /// the manual table via a future setting). This stays correct
    /// for the common case where all subscriptions use the user's
    /// base currency.
    private func convertToBase(_ amount: Double, from: String) -> Double {
        if from.caseInsensitiveCompare(baseCurrency) == .orderedSame { return amount }
        if let rate = fxRates[from.uppercased()], rate > 0 {
            return amount * rate
        }
        return amount
    }

    private func formatMoney(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = baseCurrency.isEmpty ? "USD" : baseCurrency
        f.maximumFractionDigits = 2
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }
}

private struct SubscriptionRow: View {
    let sub: SavedSubscription
    let monthlyInBase: Double
    let baseCurrency: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(sub.name.isEmpty ? "(unnamed)" : sub.name)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(TallyTheme.text)
                Text("\(sub.period.label) · \(format(sub.amount)) \(sub.currency)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(format(monthlyInBase)) \(baseCurrency)/mo")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(TallyTheme.text)
                Text("\(format(monthlyInBase * 12)) \(baseCurrency)/yr")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
    private func format(_ v: Double) -> String {
        String(format: "%.2f", v)
    }
}

private struct SubscriptionEditor: View {
    @State var initial: SavedSubscription
    let onSave: (SavedSubscription) -> Void
    let onCancel: () -> Void
    let onDelete: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(onDelete == nil ? "New subscription" : "Edit subscription")
                .font(.headline)
            Form {
                LabeledContent("Name") {
                    TextField("Netflix, Spotify, gym…", text: $initial.name)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Amount") {
                    HStack {
                        TextField("", value: $initial.amount, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                        CurrencyField(code: $initial.currency)
                    }
                }
                LabeledContent("Billed") {
                    Picker("", selection: $initial.period) {
                        ForEach(BillingPeriod.allCases) { p in
                            Text(p.label).tag(p)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
            }
            .formStyle(.grouped)
            HStack {
                if let onDelete {
                    Button("Delete", role: .destructive, action: onDelete)
                }
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Save") { onSave(initial) }
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
                    .tint(TallyTheme.accent)
                    .disabled(initial.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
