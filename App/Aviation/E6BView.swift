import SwiftUI

/// Four-tab E6B flight computer: Wind triangle / Density altitude /
/// Runway wind / Top of descent. Each tab is implemented in its own
/// file (WindTriangleTab.swift, DensityAltitudeTab.swift, etc.) and
/// the shared `NumericField` lives at `NumericField.swift`. This file
/// is just the themed segmented-tab dispatcher.
struct E6BView: View {
    private enum E6BTab: String, CaseIterable, Identifiable {
        case wind = "Wind"
        case da = "Density Alt"
        case runway = "Runway"
        case tod = "Top of Descent"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .wind:   return "wind"
            case .da:     return "thermometer.sun"
            case .runway: return "ruler"
            case .tod:    return "arrow.down.right"
            }
        }
    }

    @AppStorage("tally.e6b.tab") private var selected: String = E6BTab.wind.rawValue
    private var binding: Binding<E6BTab> {
        Binding(
            get: { E6BTab(rawValue: selected) ?? .wind },
            set: { selected = $0.rawValue }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // Themed segmented control matching the navy/cream palette.
            HStack(spacing: 6) {
                ForEach(E6BTab.allCases) { tab in
                    let isActive = binding.wrappedValue == tab
                    Button {
                        binding.wrappedValue = tab
                    } label: {
                        Label(tab.rawValue, systemImage: tab.icon)
                            .labelStyle(.titleAndIcon)
                            .font(.system(size: 12, weight: .medium))
                            .padding(.vertical, 6)
                            .padding(.horizontal, 12)
                            .frame(maxWidth: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(isActive ? TallyTheme.surface : Color.clear)
                            )
                            .foregroundStyle(isActive ? TallyTheme.text : TallyTheme.muted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(TallyTheme.surface.opacity(0.4))
            )
            .padding([.horizontal, .top], 12)

            // Active tab content
            Group {
                switch binding.wrappedValue {
                case .wind:   WindTriangleTab()
                case .da:     DensityAltitudeTab()
                case .runway: RunwayWindTab()
                case .tod:    TODTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(TallyTheme.background)
    }
}
