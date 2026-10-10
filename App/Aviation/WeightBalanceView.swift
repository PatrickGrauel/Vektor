import SwiftUI
import VektorAviation

/// Weight & balance worksheet. Stations, station limits and the CG envelope
/// polygon are all entered by the pilot from their own POH/AFM; the checks
/// (takeoff, landing after planned burn, zero fuel, station limits) live in
/// `WeightBalance.evaluate` in VektorAviation so the iPad app runs the same ones.
struct WeightBalanceView: View {
    @StateObject private var store = AircraftStore.aircraft()
    @State private var selection: String = Self.exampleTag
    @State private var profile: WBProfile = .example
    @State private var showSaveSheet = false

    private static let exampleTag = "builtin.example"
    private static let blankTag = "builtin.blank"

    var body: some View {
        let evaluation = profile.evaluate()
        Form {
            noticeSection
            profilePickerSection
            resultsSection(evaluation)
            stationsSection
            envelopeSection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(VektorTheme.background)
        .sheet(isPresented: $showSaveSheet) {
            SaveAircraftSheet(initialName: currentSaved?.name ?? "") { name in
                var saved = profile
                // Same name → overwrite that aircraft instead of duplicating it.
                saved.id = store.saved.first(where: { $0.name == name })?.id ?? UUID()
                saved.name = name
                store.add(saved)
                profile = saved
                selection = saved.id.uuidString
                showSaveSheet = false
            } onCancel: { showSaveSheet = false }
        }
    }

    // MARK: - Notice

    private var noticeSection: some View {
        Section {
            HStack(alignment: .top, spacing: 8) {
                StatusBadge(level: .caution)
                Text("Enter every station arm, station limit and envelope corner from **this airframe's** POH/AFM and current weight & balance record. The example profile is fictional and must not be used for flight.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Profile picker

    private var profilePickerSection: some View {
        Section {
            HStack {
                Picker("Aircraft profile", selection: $selection) {
                    Section("Templates") {
                        Text(WBProfile.example.name).tag(Self.exampleTag)
                        Text("New aircraft (blank)").tag(Self.blankTag)
                    }
                    if !store.saved.isEmpty {
                        Section("Saved") {
                            ForEach(store.saved) { saved in
                                Text("★ \(saved.name)").tag(saved.id.uuidString)
                            }
                        }
                    }
                }
                .onChange(of: selection) { _, tag in load(tag) }

                Button {
                    showSaveSheet = true
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }

                if let saved = currentSaved {
                    Button(role: .destructive) {
                        store.remove(saved.id)
                        selection = Self.exampleTag
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
                    Text("Max (lb)").font(.caption).foregroundStyle(.secondary)
                        .help("Station limit from the POH (e.g. baggage). Leave 0 for none.")
                    Text("Fuel").font(.caption).foregroundStyle(.secondary)
                        .help("Fuel stations are reduced by the planned burn for the landing check and emptied for the zero-fuel check.")
                    Color.clear.frame(width: 22)
                }
                Divider().gridCellColumns(7)

                ForEach($profile.stations) { $st in
                    GridRow {
                        TextField("Station", text: $st.name).textFieldStyle(.roundedBorder)
                            .labelsHidden().frame(minWidth: 150)
                        TextField("Weight", value: $st.weight, format: .number).textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .foregroundStyle(st.weight < 0 || isOverLimit(st) ? VektorTheme.statusBad : VektorTheme.text)
                        TextField("Arm", value: $st.arm,   format: .number).textFieldStyle(.roundedBorder)
                            .labelsHidden()
                        Text(String(format: "%.0f", st.weight * st.arm))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                        TextField("Max", value: limitBinding($st), format: .number).textFieldStyle(.roundedBorder)
                            .labelsHidden().frame(width: 70)
                        Toggle("", isOn: $st.isFuel).labelsHidden().toggleStyle(.checkbox)
                        Button {
                            profile.stations.removeAll { $0.id == st.id }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(VektorTheme.statusBad)
                        }
                        .buttonStyle(.plain)
                        .help("Remove this station")
                        .accessibilityLabel("Remove station")
                    }
                }
            }

            Button {
                profile.stations.append(.init(name: "Station \(profile.stations.count + 1)", weight: 0, arm: 0))
            } label: {
                Label("Add station", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderless)

            LabeledContent("Planned fuel burn (lb)") {
                TextField("", value: $profile.fuelBurn, format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 90)
            }
        } header: {
            Text("Stations")
        } footer: {
            Text("Weight in lb, arm in inches aft of datum. Fuel weight = gallons × 6 lb for avgas (check your fuel type). Planned burn should include taxi.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Envelope

    private var envelopeSection: some View {
        Section {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                GridRow {
                    Text("#").font(.caption).foregroundStyle(.secondary)
                    Text("CG (in)").font(.caption).foregroundStyle(.secondary)
                    Text("Weight (lb)").font(.caption).foregroundStyle(.secondary)
                    Color.clear.frame(width: 22)
                }
                Divider().gridCellColumns(4)
                ForEach(Array($profile.envelope.enumerated()), id: \.element.id) { index, $pt in
                    GridRow {
                        Text("\(index + 1)").foregroundStyle(.secondary).monospacedDigit()
                        TextField("CG", value: $pt.cg, format: .number).textFieldStyle(.roundedBorder)
                            .labelsHidden().frame(width: 90)
                        TextField("Weight", value: $pt.weight, format: .number).textFieldStyle(.roundedBorder)
                            .labelsHidden().frame(width: 100)
                        Button {
                            profile.envelope.removeAll { $0.id == pt.id }
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(VektorTheme.statusBad)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove envelope point")
                    }
                }
            }
            Button {
                let last = profile.envelope.last
                profile.envelope.append(.init(cg: last?.cg ?? 0, weight: last?.weight ?? 0))
            } label: {
                Label("Add envelope point", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderless)

            if profile.weightBalance.envelope?.isSimpleBox == true {
                HStack(alignment: .top, spacing: 6) {
                    StatusBadge(level: .caution)
                    Text("This envelope is a plain rectangle. Most aircraft have a forward CG limit that moves aft as weight increases — check the POH chart and add its break-point corners.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(StatusLevel.caution.colour)
            }

            WBEnvelopeChart(envelope: profile.envelope, conditions: profile.evaluate().conditions)
                .frame(height: 240)
        } header: {
            Text("CG envelope")
        } footer: {
            Text("Enter the corners of the POH's normal-category envelope in order around its outline (e.g. clockwise from the bottom-left). Its highest weight is treated as maximum takeoff weight. Limits are inclusive.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Result

    private func resultsSection(_ e: WeightBalance.Evaluation) -> some View {
        Section("Result") {
            ForEach(e.conditions, id: \.kind) { c in
                LabeledContent(c.kind.rawValue) {
                    HStack(spacing: 8) {
                        if c.result.totalWeight > 0 {
                            Text(String(format: "%.0f lb  ·  CG %.2f in  ·  moment %.0f",
                                        c.result.totalWeight, c.result.cg, c.result.totalMoment))
                                .monospacedDigit()
                            StatusBadge(level: c.result.inEnvelope == true ? .good : .bad)
                        } else {
                            Text("—")
                        }
                    }
                }
            }

            ForEach(e.problems, id: \.self) { issue in
                HStack(alignment: .top, spacing: 6) {
                    StatusBadge(level: .bad)
                    Text(issue).fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(StatusLevel.bad.colour)
            }

            let ok = e.isWithinLimits
            HStack {
                Image(systemName: ok ? "checkmark.seal.fill" : "xmark.seal.fill")
                Text(ok ? "Within limits for all conditions" : "Not within limits")
            }
            .foregroundStyle((ok ? StatusLevel.good : StatusLevel.bad).colour)
            .font(.headline)
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Helpers

    private func isOverLimit(_ st: WBProfile.Station) -> Bool {
        guard let max = st.maxWeight else { return false }
        return st.weight > max
    }

    /// 0 in the field means "no limit".
    private func limitBinding(_ st: Binding<WBProfile.Station>) -> Binding<Double> {
        Binding(
            get: { st.wrappedValue.maxWeight ?? 0 },
            set: { st.wrappedValue.maxWeight = $0 > 0 ? $0 : nil }
        )
    }

    private var currentSaved: WBProfile? {
        store.saved.first(where: { $0.id.uuidString == selection })
    }

    private func load(_ tag: String) {
        switch tag {
        case Self.exampleTag: profile = .example
        case Self.blankTag:   profile = .blank
        default:
            if let saved = store.saved.first(where: { $0.id.uuidString == tag }) { profile = saved }
        }
    }
}

// MARK: - Save sheet

private struct SaveAircraftSheet: View {
    let onSave: (String) -> Void
    let onCancel: () -> Void
    @State private var name: String

    init(initialName: String,
         onSave: @escaping (String) -> Void,
         onCancel: @escaping () -> Void) {
        self.onSave = onSave
        self.onCancel = onCancel
        self._name = State(initialValue: initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Save aircraft profile").font(.headline).foregroundStyle(VektorTheme.text)
            TextField("Aircraft name (e.g. 'PA-28-181 N12345')", text: $name)
                .textFieldStyle(.roundedBorder)
            Text("Saving under an existing name replaces that aircraft.")
                .font(.caption).foregroundStyle(.secondary)
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
