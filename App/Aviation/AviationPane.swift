import SwiftUI

/// Two-tab aviation pane: METAR/TAF/ATIS → E6B.
/// Same visual rhythm as Finance — segmented tab strip at the top, themed
/// Form below — so the pilot tools live under one pane menu entry instead
/// of three. Order follows a typical pre-flight workflow: weather →
/// flight planning → aircraft loading.
struct AviationPane: View {
    @AppStorage("vektor.aviation.tab") private var rawTab: String = AviationTab.metar.rawValue
    /// First-launch gate. Until the user explicitly accepts the disclaimer,
    /// the aviation tools are hidden — the pane shows `AviationDisclaimerView`
    /// instead. This is in addition to the README safety notice and the
    /// repo-level DISCLAIMER.md; here it puts the warning where the user
    /// will actually read it (right before they try to use the tools).
    @AppStorage("vektor.aviation.disclaimerAccepted") private var disclaimerAccepted: Bool = false

    private var tab: AviationTab {
        AviationTab(rawValue: rawTab) ?? .metar
    }

    var body: some View {
        Group {
            if disclaimerAccepted {
                tabsView
            } else {
                AviationDisclaimerView { disclaimerAccepted = true }
            }
        }
        .background(VektorTheme.background)
    }

    private var tabsView: some View {
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
                }
            }
        }
    }
}

enum AviationTab: String, CaseIterable, Identifiable {
    case metar, e6b
    var id: String { rawValue }
    var label: String {
        switch self {
        case .metar: return "METAR / TAF"
        case .e6b:   return "E6B"
        }
    }
}
