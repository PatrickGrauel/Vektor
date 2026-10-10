import SwiftUI
import VektorAviation

struct RunwayWindTab: View {
    @AppStorage("vektor.e6b.rwy.id")        private var runwayId: String = "27"
    @AppStorage("vektor.e6b.rwy.windFrom")  private var windFrom: Double = 300
    @AppStorage("vektor.e6b.rwy.windSpeed") private var windSpeed: Double = 15

    var body: some View {
        Form {
            Section("Inputs") {
                LabeledContent("Runway or exact heading") {
                    TextField("27L or 273", text: $runwayId)
                        .textFieldStyle(.roundedBorder).frame(width: 90)
                }
                NumericField(title: "Wind from",  value: $windFrom,  range: 0...360, suffix: "°")
                NumericField(title: "Wind speed", value: $windSpeed, range: 0...150, suffix: "kt")
            }
            Section {
                if let hdg = Runway.heading(fromRunwayOrHeading: runwayId) {
                    let c = Runway.components(runwayHeadingDeg: hdg, windFromDeg: windFrom, windSpeed: windSpeed)
                    LabeledContent("Runway heading", value: String(format: "%03.0f°", hdg))
                    LabeledContent(c.headwind >= 0 ? "Headwind" : "Tailwind",
                                   value: String(format: "%.0f kt", abs(c.headwind)))
                    LabeledContent("Crosswind",      value: String(format: "%.0f kt %@", c.crosswind, c.crosswind < 0.5 ? "" : (c.crosswindFromRight ? "(R)" : "(L)")))
                } else {
                    HStack(spacing: 6) {
                        StatusBadge(level: .bad)
                        Text("Invalid runway ID")
                    }
                    .foregroundStyle(StatusLevel.bad.colour)
                }
            } header: {
                Text("Components")
            } footer: {
                Text("A runway number (27) is its magnetic heading rounded to 10°, so components can be off by up to 5°; type the published 3-digit heading (273) for precision. Use wind in the runway's reference: ATIS and tower winds are magnetic, METAR/TAF winds are true.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
