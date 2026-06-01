import SwiftUI
import VektorAviation

/// Compact weight & balance for a generic C172-class single. Editable
/// station weights; computes total weight, CG, and an in-envelope check
/// against a simplified box envelope. (A full aircraft-profile editor with
/// custom envelopes is a later pass.)
struct WeightBalanceView: View {
    @AppStorage("vektor.av.wb.empty") private var emptyW = 1500.0
    @AppStorage("vektor.av.wb.pilot") private var pilotW = 340.0
    @AppStorage("vektor.av.wb.rear") private var rearW = 0.0
    @AppStorage("vektor.av.wb.bag") private var bagW = 20.0
    @AppStorage("vektor.av.wb.fuel") private var fuelW = 180.0

    // Generic C172-class station arms (in) and limits.
    private let arms: [(name: String, arm: Double)] = [
        ("Empty (BEW)", 39.0),
        ("Pilot & front", 37.0),
        ("Rear pax", 73.0),
        ("Baggage", 95.0),
        ("Fuel", 48.0),
    ]
    private let maxWeight = 2550.0
    private let minCG = 35.0
    private let maxCG = 47.3

    var body: some View {
        let weights = [emptyW, pilotW, rearW, bagW, fuelW]
        let stations = arms.enumerated().map {
            WeightBalance.Station(name: $0.element.name, weight: weights[$0.offset], armIn: $0.element.arm)
        }
        let envelope = WeightBalance.Envelope(vertices: [
            (minCG, 1000), (maxCG, 1000), (maxCG, maxWeight), (minCG, maxWeight),
        ])
        let res = WeightBalance(stations: stations, envelope: envelope).compute()
        let overGross = res.totalWeight > maxWeight
        let inEnv = (res.inEnvelope ?? false) && !overGross

        return Form {
            Section("Station weights (lb)") {
                NumberField(label: "Empty (BEW)", value: $emptyW, suffix: "lb")
                NumberField(label: "Pilot & front", value: $pilotW, suffix: "lb")
                NumberField(label: "Rear passengers", value: $rearW, suffix: "lb")
                NumberField(label: "Baggage", value: $bagW, suffix: "lb")
                NumberField(label: "Fuel", value: $fuelW, suffix: "lb")
            }
            Section("Result") {
                MetricGrid {
                    MetricBox(title: "Total weight",
                              value: String(format: "%.0f lb", res.totalWeight),
                              tone: overGross ? .bad : .good,
                              hint: "max \(Int(maxWeight)) lb")
                    MetricBox(title: "Center of gravity",
                              value: String(format: "%.1f in", res.cg))
                    MetricBox(title: "Envelope",
                              value: inEnv ? "Within limits" : "Out of limits",
                              tone: inEnv ? .good : .bad)
                    MetricBox(title: "Moment",
                              value: String(format: "%.0f", res.totalMoment))
                }
            }
        }
        .financeFormChrome("Weight & balance")
    }
}
