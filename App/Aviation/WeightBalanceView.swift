import SwiftUI
import TallyAviation

struct WeightBalanceView: View {
    @StateObject private var store = AircraftStore.aircraft()
    @State private var profileName: String = "Cessna 172 (sample)"
    @State private var stations: [EditableStation] = AircraftProfile.cessna172.stations
    @State private var envelope: EditableEnvelope = AircraftProfile.cessna172.envelope
    @State private var showSaveSheet = false
    @State private var saveName: String = ""

    var body: some View {
        Form {
            profilePickerSection
            stationsSection
            envelopeSection
            resultsSection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(TallyTheme.background)
        .sheet(isPresented: $showSaveSheet) {
            SaveAircraftSheet(initialName: profileName) { name in
                let saved = SavedAircraft(
                    id: UUID(),
                    name: name,
                    stations: stations.map { .init(id: $0.id, name: $0.name, weight: $0.weight, arm: $0.arm) },
                    envelope: .init(minCG: envelope.minCG, maxCG: envelope.maxCG, maxWeight: envelope.maxWeight)
                )
                store.add(saved)
                profileName = "★ \(name)"
                showSaveSheet = false
            } onCancel: { showSaveSheet = false }
        }
    }

    // MARK: - Profile picker

    private var profilePickerSection: some View {
        Section {
            HStack {
                Picker("Aircraft profile", selection: $profileName) {
                    Section("Built-in") {
                        ForEach(AircraftProfile.builtIn, id: \.name) { p in
                            Text(p.name).tag(p.name)
                        }
                    }
                    if !store.saved.isEmpty {
                        Section("Saved") {
                            ForEach(store.saved) { saved in
                                Text("★ \(saved.name)").tag("★ \(saved.name)")
                            }
                        }
                    }
                }
                .onChange(of: profileName) { _, newName in load(profile: newName) }

                Button {
                    saveName = profileName.hasPrefix("★ ")
                        ? String(profileName.dropFirst(2))
                        : profileName
                    showSaveSheet = true
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }

                if let saved = currentSaved {
                    Button(role: .destructive) {
                        store.remove(saved.id)
                        profileName = AircraftProfile.cessna172.name
                        load(profile: profileName)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help("Delete this saved aircraft")
                }
            }
        }
    }

    // MARK: - Stations table

    private var stationsSection: some View {
        Section {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                GridRow {
                    Text("Station").font(.caption).foregroundStyle(.secondary)
                    Text("Weight (lb)").font(.caption).foregroundStyle(.secondary)
                    Text("Arm (in)").font(.caption).foregroundStyle(.secondary)
                    Text("Moment").font(.caption).foregroundStyle(.secondary)
                    Color.clear.frame(width: 22)
                }
                Divider().gridCellColumns(5)

                ForEach($stations) { $st in
                    GridRow {
                        TextField("", text: $st.name).textFieldStyle(.roundedBorder)
                        TextField("", value: $st.weight, format: .number).textFieldStyle(.roundedBorder)
                        TextField("", value: $st.arm,   format: .number).textFieldStyle(.roundedBorder)
                        Text(String(format: "%.0f", st.weight * st.arm))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Button {
                            stations.removeAll { $0.id == st.id }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(TallyTheme.statusBad)
                        }
                        .buttonStyle(.plain)
                        .help("Remove this station")
                        .accessibilityLabel("Remove station")
                    }
                }
            }

            Button {
                stations.append(.init(name: "Station \(stations.count + 1)", weight: 0, arm: 0))
            } label: {
                Label("Add station", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderless)
        } header: {
            Text("Stations")
        } footer: {
            Text("Tip: weight in lb, arm in inches aft of datum. Save the loaded values to keep them across launches.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Envelope

    private var envelopeSection: some View {
        Section("Envelope") {
            HStack {
                LabeledContent("Min CG (in)") {
                    TextField("", value: $envelope.minCG, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 80)
                }
                LabeledContent("Max CG (in)") {
                    TextField("", value: $envelope.maxCG, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 80)
                }
                LabeledContent("Max weight (lb)") {
                    TextField("", value: $envelope.maxWeight, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 100)
                }
            }
        }
    }

    // MARK: - Result

    private var resultsSection: some View {
        Section("Result") {
            let result = computed
            LabeledContent("Total weight", value: String(format: "%.0f lb", result.totalWeight))
            LabeledContent("Total moment", value: String(format: "%.0f", result.totalMoment))
            // CG only makes sense when the airplane actually has weight on
            // it; otherwise it's 0/0 (engine clamps to 0 but that's just a
            // placeholder, not a real CG). Hide it and the envelope verdict
            // until at least one station has a non-zero weight.
            if result.totalWeight > 0 {
                LabeledContent("Center of gravity", value: String(format: "%.2f in", result.cg))
                if let inEnv = result.inEnvelope {
                    let level: StatusLevel = inEnv ? .good : .bad
                    HStack {
                        Image(systemName: inEnv ? "checkmark.seal.fill" : "xmark.seal.fill")
                        Text(inEnv ? "Within envelope" : "Out of envelope")
                    }
                    .foregroundStyle(level.colour)
                    .font(.headline)
                    .accessibilityLabel(inEnv ? "Within envelope" : "Out of envelope")
                }
            } else {
                LabeledContent("Center of gravity", value: "—")
                    .help("Enter at least one non-zero station weight to compute CG.")
            }
        }
    }

    private var computed: WeightBalance.Result {
        let wb = WeightBalance(
            stations: stations.map { .init(name: $0.name, weight: $0.weight, armIn: $0.arm) },
            envelope: .init(vertices: [
                (envelope.minCG, 0),
                (envelope.maxCG, 0),
                (envelope.maxCG, envelope.maxWeight),
                (envelope.minCG, envelope.maxWeight),
            ])
        )
        return wb.compute()
    }

    private var currentSaved: SavedAircraft? {
        guard profileName.hasPrefix("★ ") else { return nil }
        let name = String(profileName.dropFirst(2))
        return store.saved.first(where: { $0.name == name })
    }

    private func load(profile name: String) {
        if name.hasPrefix("★ ") {
            let userName = String(name.dropFirst(2))
            guard let saved = store.saved.first(where: { $0.name == userName }) else { return }
            stations = saved.stations.map { .init(name: $0.name, weight: $0.weight, arm: $0.arm) }
            envelope = .init(minCG: saved.envelope.minCG,
                             maxCG: saved.envelope.maxCG,
                             maxWeight: saved.envelope.maxWeight)
        } else if let p = AircraftProfile.builtIn.first(where: { $0.name == name }) {
            stations = p.stations
            envelope = p.envelope
        }
    }

    struct EditableStation: Identifiable, Equatable {
        var id = UUID()
        var name: String
        var weight: Double
        var arm: Double
    }

    struct EditableEnvelope: Equatable {
        var minCG: Double
        var maxCG: Double
        var maxWeight: Double
    }
}

// MARK: - Save sheet

private struct SaveAircraftSheet: View {
    let initialName: String
    let onSave: (String) -> Void
    let onCancel: () -> Void
    @State private var name: String

    init(initialName: String,
         onSave: @escaping (String) -> Void,
         onCancel: @escaping () -> Void) {
        self.initialName = initialName
        self.onSave = onSave
        self.onCancel = onCancel
        self._name = State(initialValue: initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Save aircraft profile").font(.headline).foregroundStyle(TallyTheme.text)
            TextField("Aircraft name (e.g. 'My PA-28-181 N12345')", text: $name)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    onSave(trimmed)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .themedSheet()
    }
}

// MARK: - Built-in starter profiles

private struct AircraftProfile {
    let name: String
    let stations: [WeightBalanceView.EditableStation]
    let envelope: WeightBalanceView.EditableEnvelope

    static let builtIn: [AircraftProfile] = [cessna172, piperPA28, diamondDA40, empty]

    static let cessna172 = AircraftProfile(
        name: "Cessna 172 (sample)",
        stations: [
            .init(name: "Empty",   weight: 1700, arm: 39.0),
            .init(name: "Pilot",   weight: 170,  arm: 37.0),
            .init(name: "Copilot", weight: 0,    arm: 37.0),
            .init(name: "Rear seat", weight: 0,  arm: 73.0),
            .init(name: "Fuel (40 gal)", weight: 240, arm: 48.0),
            .init(name: "Baggage A", weight: 30, arm: 95.0),
        ],
        envelope: .init(minCG: 35.0, maxCG: 47.3, maxWeight: 2300)
    )

    static let piperPA28 = AircraftProfile(
        name: "Piper PA-28 (sample)",
        stations: [
            .init(name: "Empty",   weight: 1450, arm: 86.0),
            .init(name: "Pilot",   weight: 170,  arm: 85.5),
            .init(name: "Copilot", weight: 0,    arm: 85.5),
            .init(name: "Rear seat", weight: 0,  arm: 118.0),
            .init(name: "Fuel (50 gal)", weight: 300, arm: 95.0),
            .init(name: "Baggage", weight: 20, arm: 142.0),
        ],
        envelope: .init(minCG: 82.0, maxCG: 93.0, maxWeight: 2150)
    )

    static let diamondDA40 = AircraftProfile(
        name: "Diamond DA40 (sample)",
        stations: [
            .init(name: "Empty",   weight: 1750, arm: 96.0),
            .init(name: "Front row", weight: 340, arm: 96.0),
            .init(name: "Rear row",  weight: 0,   arm: 133.0),
            .init(name: "Fuel (40 gal)", weight: 240, arm: 105.0),
            .init(name: "Baggage", weight: 30, arm: 153.0),
        ],
        envelope: .init(minCG: 94.0, maxCG: 107.0, maxWeight: 2645)
    )

    static let empty = AircraftProfile(
        name: "Custom (empty)",
        stations: [
            .init(name: "Empty", weight: 0, arm: 0),
        ],
        envelope: .init(minCG: 0, maxCG: 100, maxWeight: 10000)
    )
}
