import SwiftUI

/// Finance hub — a grouped list of the calculators. Each row pushes its tool
/// onto the detail NavigationStack (provided by RootView). Mirrors the
/// macOS app's tool grouping (Plan / Borrow / Invest / Track / Quick).
struct FinancePane: View {
    var body: some View {
        List {
            Section("Plan") {
                link("Savings goal", "Reach a target by a date", "target") { SavingsForm() }
                link("Retirement", "Will your savings last?", "figure.walk") { RetirementForm() }
            }
            Section("Borrow") {
                link("Loan", "Payment, interest, payoff", "banknote") { LoanForm() }
            }
            Section("Invest") {
                link("Real estate", "Cap rate, cash-on-cash, IRR", "house") { RealEstateForm() }
            }
            Section("Track") {
                link("Subscriptions", "Your recurring spend", "repeat") { SubscriptionsForm() }
                link("Travel budget", "Plan a trip's cost", "airplane") { TravelForm() }
            }
            Section("Quick") {
                link("Tip & split", "Split a bill", "percent") { TipForm() }
                link("Inflation", "Future buying power", "dollarsign.arrow.circlepath") { InflationForm() }
            }
        }
        .navigationTitle("Finance")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(VektorTheme.background)
    }

    private func link<D: View>(_ title: String, _ subtitle: String, _ icon: String,
                               @ViewBuilder dest: @escaping () -> D) -> some View {
        NavigationLink {
            dest()
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(VektorTheme.text)
                    Text(subtitle).font(.caption).foregroundStyle(VektorTheme.muted)
                }
            } icon: {
                Image(systemName: icon).foregroundStyle(VektorTheme.accent)
            }
        }
        .listRowBackground(VektorTheme.surface.opacity(0.5))
    }
}
