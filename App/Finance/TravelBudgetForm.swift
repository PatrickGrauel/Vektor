import SwiftUI
import TallyEngine

/// "Trip with three stops, here's what I need." Each destination has
/// days + per-day budget in the local currency; the form sums them
/// up in the user's base currency. Useful for multi-country trips
/// where each leg has its own price level.
struct TravelDestination: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var days: Int
    var perDayLocal: Double
    var currency: String

    init(id: UUID = UUID(),
         name: String = "",
         days: Int = 3,
         perDayLocal: Double = 100,
         currency: String = "EUR") {
        self.id = id
        self.name = name
        self.days = days
        self.perDayLocal = perDayLocal
        self.currency = currency
    }

    var totalLocal: Double { perDayLocal * Double(days) }
}

typealias TravelTripStore = PersistentStore<TravelDestination>

extension PersistentStore where T == TravelDestination {
    static func travel() -> TravelTripStore {
        TravelTripStore(
            storageKey: "tally.finance.travel.v1",
            matches: { $0.id == $1.id }
        )
    }
}

struct TravelBudgetForm: View {
    @StateObject private var store = TravelTripStore.travel()
    @AppStorage("tally.finance.travel.baseCurrency") private var baseCurrency: String = "EUR"
    @AppStorage("tally.finance.travel.flightsCost") private var flightsCost: Double = 600
    @AppStorage("tally.finance.travel.fxJSON") private var fxJSON: String = "{}"

    @State private var editing: TravelDestination?
    @State private var showAddSheet = false

    private var fxRates: [String: Double] {
        guard let data = fxJSON.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: Double].self, from: data)
        else { return [:] }
        return decoded
    }

    private var totalDays: Int {
        store.saved.reduce(0) { $0 + $1.days }
    }
    private var grandTotalBase: Double {
        let onTheGround = store.saved.reduce(0) { acc, d in
            acc + convertToBase(d.totalLocal, from: d.currency)
        }
        return onTheGround + flightsCost
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
        .sheet(item: $editing) { d in
            DestinationEditor(initial: d) { updated in
                store.add(updated)
                editing = nil
            } onCancel: {
                editing = nil
            } onDelete: {
                store.remove(d.id)
                editing = nil
            }
        }
        .sheet(isPresented: $showAddSheet) {
            DestinationEditor(
                initial: TravelDestination(currency: baseCurrency),
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
                    value: formatMoney(grandTotalBase),
                    label: "Trip total",
                    hint: "\(store.saved.count) leg\(store.saved.count == 1 ? "" : "s")",
                    tone: .accent
                )
                MetricBox(
                    value: "\(totalDays) days",
                    label: "On the road"
                )
                MetricBox(
                    value: totalDays > 0
                        ? formatMoney((grandTotalBase - flightsCost) / Double(totalDays))
                        : "—",
                    label: "Per day (ground)"
                )
            }
        } header: {
            Text("Trip").font(.headline)
        }
    }

    private var controlsSection: some View {
        Section {
            LabeledContent("Base currency") {
                CurrencyField(code: $baseCurrency)
            }
            LabeledContent("Flights / transport") {
                HStack {
                    TextField("", value: $flightsCost, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                    Text(baseCurrency).foregroundStyle(TallyTheme.muted)
                }
            }
            HStack {
                Spacer()
                Button {
                    showAddSheet = true
                } label: {
                    Label("Add destination", systemImage: "plus")
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
                ForEach(store.saved) { dest in
                    DestinationRow(dest: dest,
                                   inBase: convertToBase(dest.totalLocal, from: dest.currency),
                                   baseCurrency: baseCurrency)
                    .contentShape(Rectangle())
                    .onTapGesture { editing = dest }
                }
            } header: {
                Text("Destinations").font(.headline)
            } footer: {
                Text("Click any row to edit or remove a leg of the trip.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

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
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: v)) ?? "\(Int(v))"
    }
}

private struct DestinationRow: View {
    let dest: TravelDestination
    let inBase: Double
    let baseCurrency: String
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(dest.name.isEmpty ? "(unnamed)" : dest.name)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(TallyTheme.text)
                Text("\(dest.days) days · \(String(format: "%.0f", dest.perDayLocal))/day \(dest.currency)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(String(format: "%.0f", inBase)) \(baseCurrency)")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(TallyTheme.text)
                Text("on the ground")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct DestinationEditor: View {
    @State var initial: TravelDestination
    let onSave: (TravelDestination) -> Void
    let onCancel: () -> Void
    let onDelete: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(onDelete == nil ? "Add destination" : "Edit destination")
                .font(.headline)
            Form {
                LabeledContent("Name") {
                    TextField("Tokyo, Bali, Munich…", text: $initial.name)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Days") {
                    Stepper(value: $initial.days, in: 1...365) {
                        Text("\(initial.days)").monospacedDigit()
                    }
                }
                LabeledContent("Per day") {
                    HStack {
                        TextField("", value: $initial.perDayLocal, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                        CurrencyField(code: $initial.currency)
                    }
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
