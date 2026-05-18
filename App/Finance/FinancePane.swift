import SwiftUI

/// Top-level finance pane. Was a 3-tab segmented picker (Loan /
/// RealEstate / Tip); now an 8-tool sidebar grouped by purpose so
/// the next tool to land doesn't have to shove the segmented bar
/// off-screen.
///
/// Categories:
///   • Plan     — Savings goal, Retirement
///   • Borrow   — Loan
///   • Invest   — Real Estate
///   • Track    — Subscriptions, Travel budget
///   • Quick    — Tip, Inflation
///
/// Each form lives in its own file (LoanForm, RealEstateForm,
/// TipForm, SavingsGoalForm, RetirementForm, SubscriptionsForm,
/// TravelBudgetForm, InflationForm); this file is just the
/// dispatcher.
struct FinancePane: View {
    @AppStorage("tally.finance.tab") private var rawTab: String = FinanceTab.loan.rawValue
    @StateObject private var loans = LoanStore.loans()
    @StateObject private var deals = RealEstateStore.deals()

    private var tab: FinanceTab {
        FinanceTab(rawValue: rawTab) ?? .loan
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 170)
            Divider()
            content
                .frame(maxWidth: .infinity)
        }
        .background(TallyTheme.background)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(FinanceTab.Category.allCases) { cat in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cat.title.uppercased())
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(TallyTheme.muted)
                                .padding(.horizontal, 12)
                                .padding(.bottom, 2)
                            ForEach(FinanceTab.allCases.filter { $0.category == cat }) { t in
                                sidebarRow(t)
                            }
                        }
                    }
                }
                .padding(.vertical, 14)
            }
            Spacer(minLength: 0)
        }
        .background(TallyTheme.surface)
    }

    @ViewBuilder
    private func sidebarRow(_ t: FinanceTab) -> some View {
        let selected = tab == t
        Button {
            rawTab = t.rawValue
        } label: {
            HStack(spacing: 8) {
                Image(systemName: t.systemImage)
                    .foregroundStyle(selected ? TallyTheme.accent : TallyTheme.muted)
                    .frame(width: 16)
                Text(t.label)
                    .font(.callout)
                    .foregroundStyle(TallyTheme.text)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(selected ? TallyTheme.accent.opacity(0.14) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .loan:           LoanForm().environmentObject(loans)
        case .realEstate:     RealEstateForm().environmentObject(deals)
        case .savings:        SavingsGoalForm()
        case .retirement:     RetirementForm()
        case .subscriptions:  SubscriptionsForm()
        case .travel:         TravelBudgetForm()
        case .tip:            TipForm()
        case .inflation:      InflationForm()
        }
    }
}

enum FinanceTab: String, CaseIterable, Identifiable {
    case savings, retirement
    case loan
    case realEstate
    case subscriptions, travel
    case tip, inflation

    var id: String { rawValue }

    var label: String {
        switch self {
        case .savings:       return "Savings goal"
        case .retirement:    return "Retirement"
        case .loan:          return "Loan"
        case .realEstate:    return "Real Estate"
        case .subscriptions: return "Subscriptions"
        case .travel:        return "Travel budget"
        case .tip:           return "Tip"
        case .inflation:     return "Inflation"
        }
    }

    var systemImage: String {
        switch self {
        case .savings:       return "target"
        case .retirement:    return "figure.walk.motion"
        case .loan:          return "building.columns"
        case .realEstate:    return "house"
        case .subscriptions: return "creditcard"
        case .travel:        return "airplane"
        case .tip:           return "fork.knife"
        case .inflation:     return "chart.line.uptrend.xyaxis"
        }
    }

    var category: Category {
        switch self {
        case .savings, .retirement:       return .plan
        case .loan:                       return .borrow
        case .realEstate:                 return .invest
        case .subscriptions, .travel:     return .track
        case .tip, .inflation:            return .quick
        }
    }

    enum Category: String, CaseIterable, Identifiable {
        case plan, borrow, invest, track, quick
        var id: String { rawValue }
        var title: String {
            switch self {
            case .plan:   return "Plan"
            case .borrow: return "Borrow"
            case .invest: return "Invest"
            case .track:  return "Track"
            case .quick:  return "Quick"
            }
        }
    }
}
