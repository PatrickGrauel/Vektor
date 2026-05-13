import SwiftUI

/// Three-tab finance pane: Loan / Real Estate / Tip. Same visual rhythm
/// as `WeightBalanceView` — themed Form, grouped sections, result cards
/// with `LabeledContent` rows — extended with scenario save/load,
/// side-by-side comparison, and per-row "Send to Calculator" affordances.
///
/// The tab forms each live in their own file (LoanForm, RealEstateForm,
/// TipForm); shared building blocks (`ResultRow`, `SaveScenarioSheet`)
/// likewise. This file is just the segmented-tab dispatcher.
struct FinancePane: View {
    @AppStorage("tally.finance.tab") private var rawTab: String = FinanceTab.loan.rawValue
    @StateObject private var loans = LoanStore.loans()
    @StateObject private var deals = RealEstateStore.deals()

    private var tab: FinanceTab {
        FinanceTab(rawValue: rawTab) ?? .loan
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: Binding(
                get: { tab },
                set: { rawTab = $0.rawValue }
            )) {
                ForEach(FinanceTab.allCases) { t in
                    Text(t.label).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Group {
                switch tab {
                case .loan:       LoanForm().environmentObject(loans)
                case .realEstate: RealEstateForm().environmentObject(deals)
                case .tip:        TipForm()
                }
            }
        }
        .background(TallyTheme.background)
    }
}

enum FinanceTab: String, CaseIterable, Identifiable {
    case loan, realEstate, tip
    var id: String { rawValue }
    var label: String {
        switch self {
        case .loan:       return "Loan"
        case .realEstate: return "Real Estate"
        case .tip:        return "Tip"
        }
    }
}
