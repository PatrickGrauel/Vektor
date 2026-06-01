import SwiftUI

/// Top-level navigation. The macOS app uses a menu-bar pane picker; on iOS
/// we use a `NavigationSplitView` — a real sidebar on iPad (regular width)
/// that automatically collapses to a navigation stack on iPhone (compact
/// width). Same three-bucket grouping as the Mac menu.
struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var documents = DocumentStore()
    @State private var selection: Pane? = .calculator
    @State private var preferredColumn: NavigationSplitViewColumn = .detail
    @AppStorage("vektor.appearance") private var appearance: String = "system"

    // Per-module enable flags, mirroring the macOS app's keys so the
    // choice carries over conceptually. Stocks defaults off (needs a key).
    @AppStorage("vektor.panes.finance")  private var enableFinance  = true
    @AppStorage("vektor.panes.aviation") private var enableAviation = true
    @AppStorage("vektor.panes.map")      private var enableMap      = true
    @AppStorage("vektor.panes.stocks")   private var enableStocks   = false

    private var visiblePanes: [Pane] {
        Pane.allCases.filter { pane in
            switch pane {
            case .calculator, .timezone: return true
            case .finance:  return enableFinance
            case .aviation: return enableAviation
            case .map:      return enableMap
            case .stocks:   return enableStocks
            }
        }
    }

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $preferredColumn) {
            List(selection: $selection) {
                ForEach(Pane.Category.allCases, id: \.self) { category in
                    let panes = visiblePanes.filter { $0.category == category }
                    if !panes.isEmpty {
                        Section(category.rawValue) {
                            ForEach(panes) { pane in
                                Label(pane.rawValue, systemImage: pane.icon)
                                    .tag(pane)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Vektor")
            .listStyle(.sidebar)
        } detail: {
            NavigationStack {
                detail
            }
        }
        .tint(VektorTheme.accent)
        .preferredColorScheme(colorScheme(for: appearance))
        .task { await model.bootstrapLiveData() }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .calculator {
        case .calculator:
            CalculatorView(engine: model.engine,
                           error: model.engineError,
                           documents: documents)
        case .timezone:
            TimezoneView()
        case .finance:
            FinancePane()
        case .aviation:
            AviationPane()
        case .map:
            MapPane()
        default:
            PlaceholderPane(pane: selection ?? .calculator)
        }
    }

    private func colorScheme(for raw: String) -> ColorScheme? {
        switch raw {
        case "light": return .light
        case "dark":  return .dark
        default:      return nil
        }
    }
}
