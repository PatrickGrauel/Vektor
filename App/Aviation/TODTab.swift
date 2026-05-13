import SwiftUI
import TallyAviation

struct TODTab: View {
    @AppStorage("tally.e6b.tod.alt")    private var altToLose: Double = 10_000
    @AppStorage("tally.e6b.tod.rate")   private var descentRate: Double = 500
    @AppStorage("tally.e6b.tod.gs")     private var groundSpeed: Double = 120

    var body: some View {
        Form {
            Section("Inputs") {
                NumericField(title: "Altitude to lose", value: $altToLose,   range: 0...40_000, step: 500, suffix: "ft")
                NumericField(title: "Descent rate",     value: $descentRate, range: 100...3000, step: 50,  suffix: "fpm")
                NumericField(title: "Ground speed",     value: $groundSpeed, range: 0...500,    step: 5,   suffix: "kt")
            }
            Section("Top of Descent") {
                let d = Fuel.topOfDescentDistance(altitudeToLoseFt: altToLose, descentRateFpm: descentRate, groundSpeed: groundSpeed)
                let m = altToLose / descentRate
                LabeledContent("Distance",           value: String(format: "%.1f NM", d))
                LabeledContent("Time at this rate",  value: String(format: "%.1f min", m))
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
