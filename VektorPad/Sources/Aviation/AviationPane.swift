import SwiftUI

/// Aviation hub — grouped list of pilot tools. Each pushes onto the detail
/// NavigationStack. Computations come from the shared VektorAviation package;
/// live weather from VektorEngine's MetarService.
struct AviationPane: View {
    /// Same first-use gate and key as the Mac app: tools stay hidden until
    /// the pilot accepts the aviation disclaimer.
    @AppStorage("vektor.aviation.disclaimerAccepted") private var disclaimerAccepted = false

    var body: some View {
        if disclaimerAccepted {
            tools
        } else {
            AviationDisclaimerView { disclaimerAccepted = true }
                .navigationTitle("Aviation")
                .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var tools: some View {
        List {
            Section("Weather") {
                navLink("METAR / TAF", "Live observation & forecast", "cloud.sun.fill") { AvMetarView() }
            }
            Section("E6B flight computer") {
                navLink("Wind triangle", "Heading, ground speed, WCA", "wind") { WindTriangleView() }
                navLink("Density altitude", "Pressure & density altitude", "thermometer.medium") { DensityAltitudeView() }
                navLink("Runway wind", "Head / cross components", "airplane.departure") { RunwayWindView() }
                navLink("Top of descent", "Where to start down", "arrow.down.right") { TODView() }
            }
        }
        .navigationTitle("Aviation")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(VektorTheme.background)
    }

    private func navLink<D: View>(_ title: String, _ subtitle: String, _ icon: String,
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
