import SwiftUI
import TallyAviation

struct DensityAltitudeTab: View {
    @AppStorage("tally.e6b.da.indAlt")    private var indicatedAlt: Double = 5000
    @AppStorage("tally.e6b.da.altimeter") private var altimeter: Double = 29.92
    @AppStorage("tally.e6b.da.oat")       private var oat: Double = 25

    var body: some View {
        Form {
            Section("Inputs") {
                NumericField(title: "Indicated altitude", value: $indicatedAlt, range: 0...20_000, step: 100, suffix: "ft")
                NumericField(title: "Altimeter setting",  value: $altimeter,   range: 27.0...31.0, step: 0.01, suffix: "inHg",
                             format: .number.precision(.fractionLength(2)))
                NumericField(title: "Outside air temp",   value: $oat,         range: -50...55, suffix: "°C")
            }
            Section("Results") {
                let pa = Atmosphere.pressureAltitudeFt(indicatedAltitudeFt: indicatedAlt, altimeterInHg: altimeter)
                let isa = Atmosphere.isaTempC(altitudeFt: pa)
                let da = Atmosphere.densityAltitudeFt(pressureAltitudeFt: pa, oatC: oat)
                let ta = Atmosphere.trueAltitudeFt(indicatedAltitudeFt: indicatedAlt,
                                                   altimeterInHg: altimeter, oatC: oat)
                let corr = Atmosphere.trueAltitudeCorrectionFt(
                    indicatedAltitudeFt: indicatedAlt,
                    altimeterInHg: altimeter, oatC: oat
                )
                LabeledContent("Pressure Altitude", value: String(format: "%.0f ft", pa))
                LabeledContent("ISA Temperature",   value: String(format: "%.1f°C", isa))
                LabeledContent("Density Altitude",  value: String(format: "%.0f ft", da))
                LabeledContent("True Altitude",     value: String(format: "%.0f ft  (%+.0f ft vs indicated)", ta, corr))
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
