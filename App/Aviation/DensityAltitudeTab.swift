import SwiftUI
import VektorAviation

struct DensityAltitudeTab: View {
    @AppStorage("vektor.e6b.da.indAlt")    private var indicatedAlt: Double = 5000
    @AppStorage("vektor.e6b.da.altimeter") private var altimeter: Double = 29.92
    @AppStorage("vektor.e6b.da.oat")       private var oat: Double = 25
    @AppStorage("vektor.e6b.da.stationElev") private var stationElev: Double = 0

    var body: some View {
        Form {
            Section("Inputs") {
                NumericField(title: "Indicated altitude", value: $indicatedAlt, range: 0...20_000, step: 100, suffix: "ft")
                NumericField(title: "Altimeter setting",  value: $altimeter,   range: 27.0...31.0, step: 0.01, suffix: "inHg",
                             format: .number.precision(.fractionLength(2)))
                NumericField(title: "OAT at that altitude", value: $oat,       range: -60...55, suffix: "°C")
                NumericField(title: "Altimeter-source elevation", value: $stationElev, range: 0...15_000, step: 100, suffix: "ft")
            }
            Section {
                let pa = Atmosphere.pressureAltitudeFt(indicatedAltitudeFt: indicatedAlt, altimeterInHg: altimeter)
                let isa = Atmosphere.isaTempC(altitudeFt: pa)
                let da = Atmosphere.densityAltitudeFt(pressureAltitudeFt: pa, oatC: oat)
                let ta = Atmosphere.trueAltitudeFt(indicatedAltitudeFt: indicatedAlt,
                                                   altimeterInHg: altimeter, oatC: oat,
                                                   stationElevationFt: stationElev)
                LabeledContent("Pressure Altitude", value: String(format: "%.0f ft", pa))
                LabeledContent("ISA Temperature",   value: String(format: "%.1f°C (ISA %+.0f)", isa, oat - isa))
                LabeledContent("Density Altitude",  value: String(format: "%.0f ft", da))
                // One formula for both numbers, so they always agree.
                LabeledContent("True Altitude",     value: String(format: "%.0f ft  (%+.0f ft vs indicated)", ta, ta - indicatedAlt))
            } header: {
                Text("Results")
            } footer: {
                Text("Density altitude uses the FAA approximation PA + 120 ft × (OAT − ISA), which reads slightly high (conservative) versus the exact ISA formula. True altitude corrects only the air column between the altimeter-setting station and the aircraft; enter that station's elevation. For density altitude at a field, enter the field elevation as indicated altitude with the local altimeter setting and the field OAT.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
