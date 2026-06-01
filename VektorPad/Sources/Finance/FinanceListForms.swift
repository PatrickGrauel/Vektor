import SwiftUI

// MARK: - Subscriptions

struct Subscription: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var amount: Double
    var period: Period

    enum Period: String, Codable, CaseIterable, Identifiable {
        case weekly, monthly, quarterly, annual
        var id: String { rawValue }
        var perYear: Double {
            switch self {
            case .weekly: return 52
            case .monthly: return 12
            case .quarterly: return 4
            case .annual: return 1
            }
        }
        var label: String { rawValue.capitalized }
    }

    var monthly: Double { amount * period.perYear / 12 }
    var annual: Double { amount * period.perYear }
}

struct SubscriptionsForm: View {
    @AppStorage("vektor.finance.currency") private var currency = "EUR"
    @StateObject private var store = PersistentStore<Subscription>(storageKey: "vektor.finance.subs.v1")
    @State private var showAdd = false

    var body: some View {
        let monthly = store.saved.map(\.monthly).reduce(0, +)
        List {
            Section("Recurring spend") {
                MetricGrid {
                    MetricBox(title: "Per month", value: FinanceMath.money(monthly, code: currency), tone: .accent)
                    MetricBox(title: "Per year", value: FinanceMath.money(monthly * 12, code: currency), tone: .caution)
                }
                CurrencyField(code: $currency)
            }
            Section("Subscriptions") {
                if store.saved.isEmpty {
                    Text("No subscriptions yet. Add one below.")
                        .font(.caption).foregroundStyle(VektorTheme.muted)
                }
                ForEach(store.saved) { sub in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sub.name).foregroundStyle(VektorTheme.text)
                            Text(sub.period.label).font(.caption).foregroundStyle(VektorTheme.muted)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(FinanceMath.money(sub.amount, code: currency)).monospacedDigit().foregroundStyle(VektorTheme.text)
                            Text("\(FinanceMath.money(sub.monthly, code: currency)) / mo")
                                .font(.caption).foregroundStyle(VektorTheme.muted)
                        }
                    }
                }
                .onDelete { idx in idx.map { store.saved[$0].id }.forEach(store.remove) }

                Button { showAdd = true } label: {
                    Label("Add subscription", systemImage: "plus")
                }
            }
        }
        .financeFormChrome("Subscriptions")
        .sheet(isPresented: $showAdd) {
            SubscriptionEditor { store.add($0) }
        }
    }
}

private struct SubscriptionEditor: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (Subscription) -> Void
    @State private var name = ""
    @State private var amount = 9.99
    @State private var period: Subscription.Period = .monthly

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name (e.g. Netflix)", text: $name)
                NumberField(label: "Amount", value: $amount)
                Picker("Billing", selection: $period) {
                    ForEach(Subscription.Period.allCases) { Text($0.label).tag($0) }
                }
            }
            .navigationTitle("New subscription")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onSave(Subscription(name: name.isEmpty ? "Subscription" : name, amount: amount, period: period))
                        dismiss()
                    }
                }
            }
        }
        .tint(VektorTheme.accent)
    }
}

// MARK: - Travel budget

struct TravelStop: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var days: Int
    var perDay: Double
    var total: Double { Double(days) * perDay }
}

struct TravelForm: View {
    @AppStorage("vektor.finance.currency") private var currency = "EUR"
    @AppStorage("vektor.finance.travel.flights") private var flights = 600.0
    @StateObject private var store = PersistentStore<TravelStop>(storageKey: "vektor.finance.travel.v1")
    @State private var showAdd = false

    var body: some View {
        let onGround = store.saved.map(\.total).reduce(0, +)
        let totalDays = store.saved.map(\.days).reduce(0, +)
        let grand = onGround + flights
        List {
            Section("Trip cost") {
                MetricGrid {
                    MetricBox(title: "Total", value: FinanceMath.money(grand, code: currency), tone: .accent)
                    MetricBox(title: "On the ground", value: FinanceMath.money(onGround, code: currency))
                    MetricBox(title: "Flights", value: FinanceMath.money(flights, code: currency), tone: .caution)
                    MetricBox(title: "Days", value: "\(totalDays)")
                }
                CurrencyField(code: $currency)
                NumberField(label: "Flights", value: $flights, suffix: currency)
            }
            Section("Destinations") {
                if store.saved.isEmpty {
                    Text("No stops yet. Add a destination below.")
                        .font(.caption).foregroundStyle(VektorTheme.muted)
                }
                ForEach(store.saved) { stop in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(stop.name).foregroundStyle(VektorTheme.text)
                            Text("\(stop.days) days · \(FinanceMath.money(stop.perDay, code: currency))/day")
                                .font(.caption).foregroundStyle(VektorTheme.muted)
                        }
                        Spacer()
                        Text(FinanceMath.money(stop.total, code: currency)).monospacedDigit().foregroundStyle(VektorTheme.text)
                    }
                }
                .onDelete { idx in idx.map { store.saved[$0].id }.forEach(store.remove) }

                Button { showAdd = true } label: {
                    Label("Add destination", systemImage: "plus")
                }
            }
        }
        .financeFormChrome("Travel budget")
        .sheet(isPresented: $showAdd) {
            TravelEditor { store.add($0) }
        }
    }
}

private struct TravelEditor: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (TravelStop) -> Void
    @State private var name = ""
    @State private var days = 5
    @State private var perDay = 120.0

    var body: some View {
        NavigationStack {
            Form {
                TextField("Destination (e.g. Tokyo)", text: $name)
                IntStepperField(label: "Days", value: $days, range: 1...365)
                NumberField(label: "Cost per day", value: $perDay)
            }
            .navigationTitle("New destination")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onSave(TravelStop(name: name.isEmpty ? "Destination" : name, days: days, perDay: perDay))
                        dismiss()
                    }
                }
            }
        }
        .tint(VektorTheme.accent)
    }
}
