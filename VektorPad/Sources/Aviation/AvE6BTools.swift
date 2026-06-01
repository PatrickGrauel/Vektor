import SwiftUI
import VektorAviation

// MARK: - Wind triangle

struct WindTriangleView: View {
    @AppStorage("vektor.av.wt.course") private var course = 270.0
    @AppStorage("vektor.av.wt.tas") private var tas = 120.0
    @AppStorage("vektor.av.wt.windFrom") private var windFrom = 320.0
    @AppStorage("vektor.av.wt.windSpeed") private var windSpeed = 25.0

    var body: some View {
        let s = E6B.windTriangle(courseDeg: course, tas: tas, windFromDeg: windFrom, windSpeed: windSpeed)
        Form {
            Section("Route & wind") {
                NumberField(label: "True course", value: $course, suffix: "°")
                NumberField(label: "TAS", value: $tas, suffix: "kt")
                NumberField(label: "Wind from", value: $windFrom, suffix: "°")
                NumberField(label: "Wind speed", value: $windSpeed, suffix: "kt")
            }
            Section("Solution") {
                MetricGrid {
                    MetricBox(title: "Heading", value: String(format: "%03.0f°", s.headingDeg), tone: .accent)
                    MetricBox(title: "Ground speed", value: String(format: "%.0f kt", s.groundSpeed), tone: .accent)
                    MetricBox(title: "Wind correction", value: String(format: "%+.0f°", s.wcaDeg))
                    MetricBox(title: s.headwind >= 0 ? "Headwind" : "Tailwind",
                              value: String(format: "%.0f kt", abs(s.headwind)),
                              tone: s.headwind >= 0 ? .neutral : .caution)
                    MetricBox(title: "Crosswind \(s.crosswind >= 0 ? "(R)" : "(L)")",
                              value: String(format: "%.0f kt", abs(s.crosswind)),
                              tone: abs(s.crosswind) >= 20 ? .bad : .neutral)
                }
            }
        }
        .financeFormChrome("Wind triangle")
    }
}

// MARK: - Density altitude

struct DensityAltitudeView: View {
    @AppStorage("vektor.av.da.indicated") private var indicated = 1500.0
    @AppStorage("vektor.av.da.altimeter") private var altimeter = 29.92
    @AppStorage("vektor.av.da.oat") private var oat = 15.0

    var body: some View {
        let pa = Atmosphere.pressureAltitudeFt(indicatedAltitudeFt: indicated, altimeterInHg: altimeter)
        let da = Atmosphere.densityAltitudeFt(pressureAltitudeFt: pa, oatC: oat)
        let isa = Atmosphere.isaTempC(altitudeFt: pa)
        Form {
            Section("Conditions") {
                NumberField(label: "Field elevation", value: $indicated, suffix: "ft")
                NumberField(label: "Altimeter", value: $altimeter, suffix: "inHg")
                NumberField(label: "OAT", value: $oat, suffix: "°C")
            }
            Section("Result") {
                MetricGrid {
                    MetricBox(title: "Pressure altitude", value: String(format: "%.0f ft", pa))
                    MetricBox(title: "Density altitude", value: String(format: "%.0f ft", da),
                              tone: da > indicated + 2000 ? .caution : .accent)
                    MetricBox(title: "ISA temp", value: String(format: "%.0f°C", isa))
                    MetricBox(title: "ISA deviation", value: String(format: "%+.0f°C", oat - isa),
                              tone: oat - isa > 0 ? .caution : .neutral)
                }
            }
        }
        .financeFormChrome("Density altitude")
    }
}

// MARK: - Runway wind

struct RunwayWindView: View {
    @AppStorage("vektor.av.rw.runway") private var runway = "26"
    @AppStorage("vektor.av.rw.windFrom") private var windFrom = 200.0
    @AppStorage("vektor.av.rw.windSpeed") private var windSpeed = 18.0

    var body: some View {
        let heading = Runway.headingFromRunwayId(runway) ?? 0
        let c = Runway.components(runwayHeadingDeg: heading, windFromDeg: windFrom, windSpeed: windSpeed)
        Form {
            Section("Runway & wind") {
                HStack {
                    Text("Runway").foregroundStyle(VektorTheme.text)
                    Spacer()
                    TextField("26", text: $runway)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .frame(maxWidth: 90)
                    Text("→ \(Int(heading))°").font(.caption).foregroundStyle(VektorTheme.muted)
                }
                NumberField(label: "Wind from", value: $windFrom, suffix: "°")
                NumberField(label: "Wind speed", value: $windSpeed, suffix: "kt")
            }
            Section("Components") {
                MetricGrid {
                    MetricBox(title: c.headwind >= 0 ? "Headwind" : "Tailwind",
                              value: String(format: "%.0f kt", abs(c.headwind)),
                              tone: c.headwind >= 0 ? .good : .bad)
                    MetricBox(title: "Crosswind \(c.crosswindFromRight ? "from R" : "from L")",
                              value: String(format: "%.0f kt", c.crosswind),
                              tone: c.crosswind >= 20 ? .bad : (c.crosswind >= 15 ? .caution : .neutral))
                }
            }
        }
        .financeFormChrome("Runway wind")
    }
}

// MARK: - Top of descent

struct TODView: View {
    @AppStorage("vektor.av.tod.altToLose") private var altToLose = 30_000.0
    @AppStorage("vektor.av.tod.rate") private var rate = 1_800.0
    @AppStorage("vektor.av.tod.gs") private var gs = 280.0

    var body: some View {
        let dist = Fuel.topOfDescentDistance(altitudeToLoseFt: altToLose, descentRateFpm: rate, groundSpeed: gs)
        let minutes = rate > 0 ? altToLose / rate : 0
        Form {
            Section("Descent") {
                NumberField(label: "Altitude to lose", value: $altToLose, suffix: "ft")
                NumberField(label: "Descent rate", value: $rate, suffix: "fpm")
                NumberField(label: "Ground speed", value: $gs, suffix: "kt")
            }
            Section("Start down") {
                MetricGrid {
                    MetricBox(title: "Distance out", value: String(format: "%.1f NM", dist), tone: .accent)
                    MetricBox(title: "Time to descend", value: String(format: "%.0f min", minutes))
                }
            }
        }
        .financeFormChrome("Top of descent")
    }
}
