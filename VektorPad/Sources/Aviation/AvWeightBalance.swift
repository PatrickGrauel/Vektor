import SwiftUI
import VektorAviation

/// Weight & balance worksheet. Every station, station limit and envelope
/// corner is entered by the pilot from their POH/AFM; the checks (takeoff,
/// landing after planned burn, zero fuel, station limits) come from
/// `WeightBalance.evaluate` in VektorAviation — the same code the Mac app runs.
/// The working profile persists as JSON in `vektor.av.wb.profile`.
struct WeightBalanceView: View {
    @AppStorage("vektor.av.wb.profile") private var storedJSON: String = ""
    @State private var profile: WBProfile = .example
    @State private var loaded = false
    @State private var confirmTemplate: WBProfile?

    var body: some View {
        let e = profile.evaluate()
        Form {
            Section {
                Label {
                    Text("Enter every arm, station limit and envelope corner from **this airframe's** POH/AFM and current weight & balance record. The example is fictional — not for flight.")
                        .font(.callout)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(VektorTheme.statusCaution)
                }
                TextField("Aircraft name", text: $profile.name)
                HStack {
                    Button("Load example") { confirmTemplate = .example }
                    Spacer()
                    Button("Start blank") { confirmTemplate = .blank }
                }
                .buttonStyle(.borderless)
            }

            resultSection(e)

            Section {
                ForEach($profile.stations) { $st in
                    stationRow($st)
                }
                .onDelete { profile.stations.remove(atOffsets: $0) }
                Button {
                    profile.stations.append(.init(name: "Station \(profile.stations.count + 1)", weight: 0, arm: 0))
                } label: {
                    Label("Add station", systemImage: "plus.circle.fill")
                }
                NumberField(label: "Planned fuel burn", value: $profile.fuelBurn, suffix: "lb")
            } header: {
                Text("Stations (lb, in aft of datum)")
            } footer: {
                Text("Max = station limit from the POH (0 = none). Fuel stations are reduced by the burn for the landing check and emptied for zero fuel. Avgas ≈ 6 lb/gal.")
            }

            Section {
                ForEach(Array($profile.envelope.enumerated()), id: \.element.id) { index, $pt in
                    HStack {
                        Text("\(index + 1)").foregroundStyle(VektorTheme.muted).monospacedDigit().frame(width: 22)
                        Text("CG").foregroundStyle(VektorTheme.muted)
                        TextField("in", value: $pt.cg, format: .number)
                            .keyboardType(.decimalPad).monospacedDigit()
                        Text("Weight").foregroundStyle(VektorTheme.muted)
                        TextField("lb", value: $pt.weight, format: .number)
                            .keyboardType(.decimalPad).monospacedDigit()
                    }
                }
                .onDelete { profile.envelope.remove(atOffsets: $0) }
                .onMove { profile.envelope.move(fromOffsets: $0, toOffset: $1) }
                Button {
                    let last = profile.envelope.last
                    profile.envelope.append(.init(cg: last?.cg ?? 0, weight: last?.weight ?? 0))
                } label: {
                    Label("Add envelope corner", systemImage: "plus.circle.fill")
                }
                if profile.weightBalance.envelope?.isSimpleBox == true {
                    Label("This envelope is a plain rectangle. Most aircraft have a forward CG limit that moves aft with weight — add the POH chart's break-point corners.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(VektorTheme.statusCaution)
                        .font(.callout)
                }
                WBEnvelopeChart(envelope: profile.envelope, conditions: e.conditions)
                    .frame(height: 220)
            } header: {
                Text("CG envelope")
            } footer: {
                Text("Enter the corners of the POH envelope in order around its outline. Its highest weight is treated as maximum takeoff weight. Limits are inclusive.")
            }
        }
        .financeFormChrome("Weight & balance")
        .onAppear(perform: loadStored)
        .onChange(of: profile) { _, p in save(p) }
        .confirmationDialog("Replace the current aircraft?", isPresented: Binding(
            get: { confirmTemplate != nil }, set: { if !$0 { confirmTemplate = nil } }
        ), titleVisibility: .visible) {
            Button("Replace", role: .destructive) {
                if let t = confirmTemplate { profile = t }
                confirmTemplate = nil
            }
        }
    }

    private func stationRow(_ st: Binding<WBProfile.Station>) -> some View {
        let s = st.wrappedValue
        let bad = s.weight < 0 || (s.maxWeight.map { s.weight > $0 } ?? false)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Station", text: st.name).foregroundStyle(VektorTheme.text)
                TextField("lb", value: st.weight, format: .number)
                    .keyboardType(.numbersAndPunctuation)
                    .multilineTextAlignment(.trailing).monospacedDigit()
                    .foregroundStyle(bad ? VektorTheme.statusBad : VektorTheme.text)
                    .frame(maxWidth: 90)
                Text("lb").font(.caption).foregroundStyle(VektorTheme.muted)
            }
            HStack(spacing: 10) {
                Text("Arm").font(.caption).foregroundStyle(VektorTheme.muted)
                TextField("in", value: st.arm, format: .number)
                    .keyboardType(.decimalPad).monospacedDigit().frame(maxWidth: 70)
                Text("Max").font(.caption).foregroundStyle(VektorTheme.muted)
                TextField("none", value: Binding(
                    get: { st.wrappedValue.maxWeight ?? 0 },
                    set: { st.wrappedValue.maxWeight = $0 > 0 ? $0 : nil }
                ), format: .number)
                    .keyboardType(.decimalPad).monospacedDigit().frame(maxWidth: 70)
                Spacer()
                Toggle("Fuel", isOn: st.isFuel).fixedSize()
                    .font(.caption)
            }
        }
    }

    private func resultSection(_ e: WeightBalance.Evaluation) -> some View {
        Section("Result") {
            MetricGrid {
                ForEach(e.conditions, id: \.kind) { c in
                    MetricBox(title: c.kind.rawValue,
                              value: c.result.totalWeight > 0
                                ? String(format: "CG %.2f in", c.result.cg) : "—",
                              tone: c.result.inEnvelope == true ? .good : .bad,
                              hint: String(format: "%.0f lb · moment %.0f", c.result.totalWeight, c.result.totalMoment))
                }
            }
            ForEach(e.problems, id: \.self) { issue in
                Label(issue, systemImage: "xmark.octagon.fill").foregroundStyle(VektorTheme.statusBad)
            }
            Label(e.isWithinLimits ? "Within limits for all conditions" : "Not within limits",
                  systemImage: e.isWithinLimits ? "checkmark.seal.fill" : "xmark.seal.fill")
                .font(.headline)
                .foregroundStyle(e.isWithinLimits ? VektorTheme.statusGood : VektorTheme.statusBad)
        }
    }

    private func loadStored() {
        guard !loaded else { return }
        loaded = true
        if let data = storedJSON.data(using: .utf8),
           let p = try? JSONDecoder().decode(WBProfile.self, from: data) {
            profile = p
        }
    }

    private func save(_ p: WBProfile) {
        guard loaded, let data = try? JSONEncoder().encode(p),
              let json = String(data: data, encoding: .utf8) else { return }
        storedJSON = json
    }
}
