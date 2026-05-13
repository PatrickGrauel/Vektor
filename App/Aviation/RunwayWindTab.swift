import SwiftUI
import TallyAviation

struct RunwayWindTab: View {
    @AppStorage("tally.e6b.rwy.id")        private var runwayId: String = "27"
    @AppStorage("tally.e6b.rwy.windFrom")  private var windFrom: Double = 300
    @AppStorage("tally.e6b.rwy.windSpeed") private var windSpeed: Double = 15

    var body: some View {
        Form {
            Section("Inputs") {
                LabeledContent("Runway") {
                    TextField("e.g. 27L", text: $runwayId)
                        .textFieldStyle(.roundedBorder).frame(width: 90)
                }
                NumericField(title: "Wind from",  value: $windFrom,  range: 0...360, suffix: "°")
                NumericField(title: "Wind speed", value: $windSpeed, range: 0...80,  suffix: "kt")
            }
            Section("Components") {
                if let hdg = Runway.headingFromRunwayId(runwayId) {
                    let c = Runway.components(runwayHeadingDeg: hdg, windFromDeg: windFrom, windSpeed: windSpeed)
                    LabeledContent("Runway heading", value: "\(Int(hdg))°")
                    LabeledContent("Headwind",       value: String(format: "%+.0f kt", c.headwind))
                    LabeledContent("Crosswind",      value: String(format: "%.0f kt %@", c.crosswind, c.crosswindFromRight ? "(R)" : "(L)"))
                } else {
                    HStack(spacing: 6) {
                        StatusBadge(level: .bad)
                        Text("Invalid runway ID")
                    }
                    .foregroundStyle(StatusLevel.bad.colour)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
