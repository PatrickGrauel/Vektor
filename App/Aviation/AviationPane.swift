import SwiftUI

/// Three-tab aviation pane: METAR/TAF/ATIS → E6B → Weight & Balance.
/// Same visual rhythm as Finance — segmented tab strip at the top, themed
/// Form below — so the pilot tools live under one pane menu entry instead
/// of three. Order follows a typical pre-flight workflow: weather →
/// flight planning → aircraft loading.
struct AviationPane: View {
    @AppStorage("tally.aviation.tab") private var rawTab: String = AviationTab.metar.rawValue

    private var tab: AviationTab {
        AviationTab(rawValue: rawTab) ?? .metar
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: Binding(
                get: { tab },
                set: { rawTab = $0.rawValue }
            )) {
                ForEach(AviationTab.allCases) { t in
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
                case .metar:  MetarView()
                case .e6b:    E6BView()
                case .wb:     WeightBalanceView()
                }
            }
        }
        .background(TallyTheme.background)
    }
}

enum AviationTab: String, CaseIterable, Identifiable {
    case metar, e6b, wb
    var id: String { rawValue }
    var label: String {
        switch self {
        case .metar: return "METAR / TAF"
        case .e6b:   return "E6B"
        case .wb:    return "Weight & Balance"
        }
    }
}
