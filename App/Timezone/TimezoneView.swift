import SwiftUI
import MapKit
import TallyEngine

/// A city the user has pinned for quick reference. Stored in UserDefaults
/// as a JSON-encoded array. `timeZoneId` is optional for backward-compat
/// with pins saved before we started capturing it; the row falls back to
/// name-resolution when nil.
///
/// Working-hour data drives the multi-city time strip and the "best slot"
/// suggester. All fields default to standard 09:00–18:00 Mon–Fri so a
/// freshly-pinned city behaves reasonably without the user editing
/// anything. Codable decode tolerates older pins that have none of these
/// fields, so upgrading users keep their saved set.
struct PinnedCity: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var latitude: Double
    var longitude: Double
    var timeZoneId: String?

    /// Working hours in the pin's *local* time. 24-hour format, inclusive
    /// start, exclusive end (so `9..<18` is 09:00–17:59).
    var workStartHour: Int = 9
    var workEndHour: Int = 18
    /// Gregorian weekday indices: Sunday = 1 … Saturday = 7. Defaults to
    /// Mon–Fri (2…6) to match the global business norm.
    var workDays: [Int] = [2, 3, 4, 5, 6]

    init(id: UUID = UUID(),
         name: String,
         latitude: Double,
         longitude: Double,
         timeZoneId: String? = nil,
         workStartHour: Int = 9,
         workEndHour: Int = 18,
         workDays: [Int] = [2, 3, 4, 5, 6]) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.timeZoneId = timeZoneId
        self.workStartHour = workStartHour
        self.workEndHour = workEndHour
        self.workDays = workDays
    }

    // Custom decoder so old pins (no working-hour fields) decode cleanly
    // with the defaults above.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.name = try c.decode(String.self, forKey: .name)
        self.latitude = try c.decode(Double.self, forKey: .latitude)
        self.longitude = try c.decode(Double.self, forKey: .longitude)
        self.timeZoneId = try c.decodeIfPresent(String.self, forKey: .timeZoneId)
        self.workStartHour = try c.decodeIfPresent(Int.self, forKey: .workStartHour) ?? 9
        self.workEndHour   = try c.decodeIfPresent(Int.self, forKey: .workEndHour) ?? 18
        self.workDays      = try c.decodeIfPresent([Int].self, forKey: .workDays) ?? [2, 3, 4, 5, 6]
    }

    /// Best-effort TimeZone. Prefers the stored identifier; falls back to
    /// the engine's name-based resolver for legacy pins.
    var resolvedTimeZone: TimeZone? {
        if let id = timeZoneId, let tz = TimeZone(identifier: id) { return tz }
        return TimezoneBridge.resolve(name)
    }

    /// Is the given `Date` inside this city's working hours (in its own
    /// local time)?
    func isWorkingHour(_ date: Date) -> Bool {
        guard let tz = resolvedTimeZone else { return false }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let c = cal.dateComponents([.weekday, .hour], from: date)
        guard let w = c.weekday, let h = c.hour else { return false }
        return workDays.contains(w) && h >= workStartHour && h < workEndHour
    }
}

/// Curated list of well-known cities with coordinates. Used as the picker source.
struct CityCatalog {
    static let all: [PinnedCity] = [
        .init(name: "New York",     latitude: 40.7128, longitude: -74.0060),
        .init(name: "Los Angeles",  latitude: 34.0522, longitude: -118.2437),
        .init(name: "Chicago",      latitude: 41.8781, longitude: -87.6298),
        .init(name: "Denver",       latitude: 39.7392, longitude: -104.9903),
        .init(name: "Miami",        latitude: 25.7617, longitude: -80.1918),
        .init(name: "Toronto",      latitude: 43.6532, longitude: -79.3832),
        .init(name: "Mexico City",  latitude: 19.4326, longitude: -99.1332),
        .init(name: "São Paulo",    latitude: -23.5505, longitude: -46.6333),
        .init(name: "Buenos Aires", latitude: -34.6037, longitude: -58.3816),
        .init(name: "London",       latitude: 51.5074, longitude: -0.1278),
        .init(name: "Paris",        latitude: 48.8566, longitude: 2.3522),
        .init(name: "Berlin",       latitude: 52.5200, longitude: 13.4050),
        .init(name: "Munich",       latitude: 48.1351, longitude: 11.5820),
        .init(name: "Vienna",       latitude: 48.2082, longitude: 16.3738),
        .init(name: "Rome",         latitude: 41.9028, longitude: 12.4964),
        .init(name: "Madrid",       latitude: 40.4168, longitude: -3.7038),
        .init(name: "Amsterdam",    latitude: 52.3676, longitude: 4.9041),
        .init(name: "Zurich",       latitude: 47.3769, longitude: 8.5417),
        .init(name: "Stockholm",    latitude: 59.3293, longitude: 18.0686),
        .init(name: "Moscow",       latitude: 55.7558, longitude: 37.6173),
        .init(name: "Istanbul",     latitude: 41.0082, longitude: 28.9784),
        .init(name: "Dubai",        latitude: 25.2048, longitude: 55.2708),
        .init(name: "Tel Aviv",     latitude: 32.0853, longitude: 34.7818),
        .init(name: "Mumbai",       latitude: 19.0760, longitude: 72.8777),
        .init(name: "Delhi",        latitude: 28.7041, longitude: 77.1025),
        .init(name: "Bangkok",      latitude: 13.7563, longitude: 100.5018),
        .init(name: "Singapore",    latitude: 1.3521,  longitude: 103.8198),
        .init(name: "Hong Kong",    latitude: 22.3193, longitude: 114.1694),
        .init(name: "Shanghai",     latitude: 31.2304, longitude: 121.4737),
        .init(name: "Beijing",      latitude: 39.9042, longitude: 116.4074),
        .init(name: "Tokyo",        latitude: 35.6762, longitude: 139.6503),
        .init(name: "Seoul",        latitude: 37.5665, longitude: 126.9780),
        .init(name: "Sydney",       latitude: -33.8688, longitude: 151.2093),
        .init(name: "Melbourne",    latitude: -37.8136, longitude: 144.9631),
        .init(name: "Auckland",     latitude: -36.8485, longitude: 174.7633),
        .init(name: "Honolulu",     latitude: 21.3069, longitude: -157.8583),
    ]
}

@MainActor
final class PinnedCityStore: ObservableObject {
    @Published var cities: [PinnedCity]

    private static let storageKey = "tally.timezone.cities"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([PinnedCity].self, from: data),
           !decoded.isEmpty {
            self.cities = decoded
        } else {
            // Don't crash if the catalog has been edited / renamed — fall
            // back to the first few cities available, then to an empty list
            // as a last resort.
            let seedNames = ["New York", "London", "Berlin", "Tokyo"]
            let seeded = seedNames.compactMap { name in
                CityCatalog.all.first(where: { $0.name == name })
            }
            self.cities = seeded.isEmpty
                ? Array(CityCatalog.all.prefix(4))
                : seeded
            persist()
        }
    }

    func add(_ city: PinnedCity) {
        guard !cities.contains(where: { $0.name == city.name }) else { return }
        cities.append(city); persist()
    }

    /// Replace a pin by id. Used by the working-hours editor.
    func update(_ city: PinnedCity) {
        if let idx = cities.firstIndex(where: { $0.id == city.id }) {
            cities[idx] = city; persist()
        }
    }

    func remove(_ city: PinnedCity) {
        cities.removeAll { $0.id == city.id }; persist()
    }

    /// Move the pin at `from` to `to`. `to` follows SwiftUI's `onMove`
    /// convention: it is the index the moved element should *end up at*,
    /// after taking into account the removal — so `to > from` means
    /// "after the current position by (to - from - 1) slots." Use
    /// `move(fromOffsets:toOffset:)` to get the right semantics for
    /// free.
    func move(from source: Int, to destination: Int) {
        guard source >= 0, source < cities.count,
              destination >= 0, destination <= cities.count,
              source != destination
        else { return }
        cities.move(fromOffsets: IndexSet(integer: source), toOffset: destination)
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(cities) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}

struct TimezoneView: View {
    @StateObject private var store = PinnedCityStore()
    @State private var sourceCity: String = "New York"
    @State private var targetCity: String = "Berlin"
    /// The shared "selected moment" — drives the strip cursor, the
    /// converter, the snippet text, and the calendar event. Replaces the
    /// previous local `date` state.
    @State private var cursor: Date = Date()
    @State private var converted: String = ""
    @State private var showingCityPicker = false
    @State private var showingPlaceSearch = false
    @State private var editingCity: PinnedCity? = nil
    @State private var refreshTrigger = false
    @State private var mapTickTrigger = false  // re-render terminator every minute
    @State private var lastTappedCoord: CLLocationCoordinate2D?
    @State private var showingAddSheetForCoord: CLLocationCoordinate2D?
    @State private var calendarFeedback: String? = nil
    @State private var showingCalendarConfirm: Bool = false
    /// Collapses the Meeting scheduler block by default — most visits to
    /// the pane are "what time is it in X?" / "convert this moment", not
    /// "find a slot for everyone." Persisted so a user who reaches for
    /// the scheduler regularly doesn't have to re-open it every launch.
    @AppStorage("tally.timezone.schedulerExpanded") private var schedulerExpanded: Bool = false

    private let bridge = TimezoneBridge()
    private let cityClock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    private let mapClock  = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        VSplitView {
            mapView
                .frame(minHeight: 220)

            Form {
                // Order reflects how often each task happens:
                //   1. Glance — "what time is it in X?"         → Pinned places
                //   2. Convert one moment — "X at 2pm in Y?"   → Convert
                //   3. Find a meeting slot — rarer, opt-in     → Meeting scheduler
                pinnedSection
                conversionSection
                schedulerSection
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .background(TallyTheme.background)
        .onChange(of: sourceCity) { _, _ in recompute() }
        .onChange(of: targetCity) { _, _ in recompute() }
        .onChange(of: cursor)     { _, _ in recompute() }
        .onAppear { recompute() }
        .onReceive(cityClock) { _ in refreshTrigger.toggle() }
        .onReceive(mapClock)  { _ in mapTickTrigger.toggle() }
        .sheet(isPresented: $showingCityPicker) {
            CityPickerSheet { city in
                store.add(city); showingCityPicker = false
            }
        }
        .sheet(isPresented: $showingPlaceSearch) {
            PlaceSearchSheet(
                onPick: { city in
                    store.add(city)
                    // Auto-select the freshly-added place as the To city
                    // — usually the reason the user typed it in.
                    targetCity = city.name
                    showingPlaceSearch = false
                },
                onCancel: { showingPlaceSearch = false }
            )
        }
        .sheet(item: $editingCity) { city in
            WorkingHoursEditor(city: Binding(
                get: { city },
                set: { updated in store.update(updated) }
            )) { editingCity = nil }
        }
        .sheet(isPresented: $showingCalendarConfirm) {
            CalendarConfirmSheet(
                cursor: cursor,
                cities: store.cities,
                onConfirm: { options in
                    showingCalendarConfirm = false
                    Task { await createCalendarEvent(options) }
                },
                onCancel: { showingCalendarConfirm = false }
            )
        }
        .sheet(item: CoordWrapper.binding($showingAddSheetForCoord)) { wrapper in
            AddPinFromCoordSheet(coordinate: wrapper.coordinate) { city in
                if let city { store.add(city) }
                showingAddSheetForCoord = nil
            }
        }
    }

    // MARK: - Map view (with day/night curve + click-to-add)

    private var mapView: some View {
        ZStack {
            MapWithDayNight(
                cities: store.cities,
                terminator: DayNightCurve.points(),
                onTap: { coord in
                    showingAddSheetForCoord = coord
                }
            )
            .id(mapTickTrigger)   // forces redraw of terminator each minute

            // Subtle overlay legend so users notice the curve.
            VStack {
                HStack {
                    Spacer()
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.yellow.opacity(0.4))
                            .frame(width: 8, height: 8)
                        Text("Day · Night terminator")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.7))
                        Divider().frame(height: 10)
                        Text("Tap map to pin a place")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.45), in: .capsule)
                    .padding(8)
                }
                Spacer()
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: - Meeting scheduler (collapsible)
    //
    // Combines the time strip, the best-slots suggester, the DST warning,
    // and the share/calendar actions into a single section that's
    // collapsed by default. Most visits to the pane are about ambient
    // time awareness; the scheduler is here when you need it, out of
    // sight when you don't.

    private var schedulerSection: some View {
        Section {
            if schedulerExpanded {
                if store.cities.isEmpty {
                    Text("Add at least one pinned place to use the scheduler.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    TimeStripView(
                        cities: store.cities,
                        cursor: $cursor,
                        onMove: { from, to in store.move(from: from, to: to) }
                    )
                        .padding(.vertical, 4)
                    HStack(spacing: 8) {
                        DatePicker("",
                                   selection: $cursor,
                                   displayedComponents: [.date, .hourAndMinute])
                            .labelsHidden()
                        Spacer()
                        Button("Now") { cursor = Date() }
                            .buttonStyle(.borderless)
                            .help("Reset cursor to the current moment")
                    }
                    Text("Bright cells are working hours; dimmed are after-hours; dark are sleeping (22:00–07:00). Drag any row to scrub the cursor; click a cell to jump.")
                        .font(.caption2).foregroundStyle(.secondary)
                    dstWarningBlock
                    shareBlock
                }
            }
        } header: {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { schedulerExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "calendar.badge.clock")
                        .foregroundStyle(TallyTheme.muted)
                    Text("Meeting scheduler")
                    Spacer()
                    Image(systemName: schedulerExpanded ? "chevron.up" : "chevron.down")
                        .foregroundStyle(TallyTheme.muted)
                        .font(.caption.weight(.semibold))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(schedulerExpanded ? "Collapse meeting scheduler" : "Plan a meeting across pinned places")
        }
    }

    // MARK: - Scheduler sub-blocks (rendered inside schedulerSection)

    @ViewBuilder
    private var dstWarningBlock: some View {
        if let (city, when) = DSTDetector.upcomingTransition(in: store.cities, from: cursor),
           when.timeIntervalSince(cursor) < 28 * 86400 {
            Divider().padding(.vertical, 4)
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(TallyTheme.statusCaution)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(city.name) shifts its clock \(dstRelative(when))")
                        .foregroundStyle(TallyTheme.text)
                    Text("Recurring meetings that cross this date may not line up the same way after the transition.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var shareBlock: some View {
        Divider().padding(.vertical, 4)
        Button {
            calendarFeedback = nil
            showingCalendarConfirm = true
        } label: {
            Label("Add to Calendar…", systemImage: "calendar.badge.plus")
        }
        .buttonStyle(.borderless)
        .help("Open a confirm sheet to set title, duration, and location before saving")
        if let feedback = calendarFeedback {
            Text(feedback)
                .font(.caption)
                .foregroundStyle(TallyTheme.muted)
        }
    }

    // MARK: - Two-city converter (legacy quick lookup)

    private var conversionSection: some View {
        Section("Convert specific time") {
            HStack(spacing: 4) {
                cityPicker(label: "From", selection: $sourceCity)
                Button {
                    let from = sourceCity
                    sourceCity = targetCity
                    targetCity = from
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(TallyTheme.muted)
                .help("Swap From and To")
                .accessibilityLabel("Swap source and target cities")
                cityPicker(label: "To", selection: $targetCity)
            }
            LabeledContent("Converted") {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(converted.isEmpty ? "—" : converted)
                        .font(.system(.body, design: .monospaced))
                    if let label = dayShiftLabel {
                        Text(label)
                            .font(.caption2)
                            .foregroundStyle(TallyTheme.accent)
                    }
                }
            }
        }
    }

    // MARK: - Pinned cities

    private var pinnedSection: some View {
        Section {
            ForEach(store.cities) { city in
                PinnedCityRow(
                    city: city,
                    bridge: bridge,
                    refreshTrigger: refreshTrigger,
                    onEdit: { editingCity = city },
                    onRemove: { store.remove(city) }
                )
            }
            Button {
                showingPlaceSearch = true
            } label: {
                Label("Add a place…", systemImage: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Search any address worldwide and pin it")
        } header: {
            Text("Pinned places")
        } footer: {
            Text("Tap a place to edit its working hours.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Picker

    private func cityPicker(label: String, selection: Binding<String>) -> some View {
        Picker(label, selection: selection) {
            // The pinned list is the canonical "places I care about" —
            // catalog entries appear only when no pin matches by name,
            // so they remain available as bootstrap defaults until the
            // user customises.
            ForEach(pickerCities, id: \.id) { city in
                Text(city.name).tag(city.name)
            }
            Divider()
            Text("Add a place…").tag("__add_place__")
        }
        .onChange(of: selection.wrappedValue) { _, new in
            if new == "__add_place__" {
                selection.wrappedValue = pickerCities.first?.name ?? new
                showingPlaceSearch = true
            }
        }
    }

    private var pickerCities: [PinnedCity] {
        if store.cities.isEmpty { return CityCatalog.all }
        let pinnedNames = Set(store.cities.map(\.name))
        let extras = CityCatalog.all.filter { !pinnedNames.contains($0.name) }
            .filter { $0.name == sourceCity || $0.name == targetCity }
        return store.cities + extras
    }

    // MARK: - Helpers

    private var dayShiftLabel: String? {
        guard let from = tz(for: sourceCity),
              let to   = tz(for: targetCity)
        else { return nil }
        var calFrom = Calendar(identifier: .gregorian); calFrom.timeZone = from
        var calTo   = Calendar(identifier: .gregorian); calTo.timeZone   = to
        let fromDay = calFrom.component(.day, from: cursor)
        let toDay   = calTo.component(.day, from: cursor)
        if fromDay == toDay { return nil }
        let fromOrdinal = calFrom.ordinality(of: .day, in: .era, for: cursor) ?? 0
        let toOrdinal   = calTo.ordinality(of: .day, in: .era, for: cursor) ?? 0
        let delta = toOrdinal - fromOrdinal
        if delta > 0  { return "+\(delta) day" }
        if delta < 0  { return "\(delta) day" }
        return nil
    }

    private func dstRelative(_ when: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "EEE d MMM"
        return "on \(fmt.string(from: when))"
    }

    private func createCalendarEvent(_ options: CalendarSaveOptions) async {
        let snippet = SchedulingSnippet.format(store.cities, at: options.startsAt)
        let outcome = await CalendarExporter.create(
            date: options.startsAt,
            notes: snippet,
            options: options
        )
        switch outcome {
        case .created:
            calendarFeedback = options.openInCalendar
                ? "Added “\(options.title)” to Calendar and opened it."
                : "Added “\(options.title)” to Calendar."
        case .denied:
            calendarFeedback = "Calendar access denied. Enable in System Settings → Privacy → Calendars."
        case .error(let msg):
            calendarFeedback = "Calendar error: \(msg)"
        }
    }

    /// Look up the timezone for a city name by walking the pinned-cities
    /// list first (so arbitrary place names like "Uluwatu" — pinned via
    /// the MapKit search — work), then falling back to the engine's
    /// curated alias resolver for the catalog-name cases.
    private func tz(for name: String) -> TimeZone? {
        if let pinned = store.cities.first(where: { $0.name == name }),
           let tz = pinned.resolvedTimeZone {
            return tz
        }
        return TimezoneBridge.resolve(name)
    }

    private func recompute() {
        guard let from = tz(for: sourceCity), let to = tz(for: targetCity) else {
            converted = "Cannot resolve one of the timezones"
            return
        }
        // The cursor is already an absolute instant — to "convert" it, we
        // just format it in the destination timezone. The old path of
        // parsing-then-reformatting was an artefact of the original
        // string-based bridge API and produced wrong answers as soon as
        // the source timezone wasn't in the curated alias list.
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "HH:mm zzz"
        fmt.timeZone = to
        let formatted = fmt.string(from: cursor)
        let canonical = to.identifier
        converted = "\(formatted)  (\(canonical))"
        // Suppress the unused `from` warning while keeping the symmetric
        // null-check above — `from` matters for the day-shift label
        // elsewhere in the view.
        _ = from
    }
}

// MARK: - PinnedCityRow

private struct PinnedCityRow: View {
    let city: PinnedCity
    let bridge: TimezoneBridge
    let refreshTrigger: Bool
    let onEdit: () -> Void
    let onRemove: () -> Void

    @State private var hovering = false

    /// Prefer the IANA identifier stored on the pin (captured at add time
    /// from the placemark or the catalog). Fall back to the engine's
    /// name-based resolver only when the pin doesn't carry one — older
    /// pins from before the field existed, or catalog entries the
    /// resolver doesn't recognise.
    private var formattedNow: String {
        if let tz = city.resolvedTimeZone {
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.dateFormat = "HH:mm zzz"
            fmt.timeZone = tz
            return fmt.string(from: Date())
        }
        return bridge.nowString(in: city.name)?.formatted ?? "—"
    }

    /// Compact working-hours label, e.g. "Mo–Fr 09–18".
    private var workingHoursLabel: String {
        let daysShort = city.workDays.sorted()
        guard let first = daysShort.first, let last = daysShort.last else { return "" }
        let symbols = ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"]
        let days: String
        if daysShort.count == 5 && daysShort == [2,3,4,5,6] {
            days = "Mo–Fr"
        } else if daysShort.count == 7 {
            days = "daily"
        } else if daysShort.count == 1 {
            days = symbols[first - 1]
        } else {
            days = "\(symbols[first - 1])–\(symbols[last - 1])"
        }
        return "\(days) \(String(format: "%02d–%02d", city.workStartHour, city.workEndHour))"
    }

    var body: some View {
        HStack {
            Image(systemName: "mappin.circle.fill")
                .foregroundStyle(TallyTheme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(city.name)
                Text(workingHoursLabel)
                    .font(.caption2)
                    .foregroundStyle(TallyTheme.muted)
            }
            Spacer()
            Text(formattedNow)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .id(refreshTrigger)
            Button { onRemove() } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(TallyTheme.muted)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1.0 : 0.35)
            .help("Remove pin")
            .accessibilityLabel("Remove \(city.name)")
        }
        .contentShape(Rectangle())
        .onTapGesture { onEdit() }
        .onHover { hovering = $0 }
    }
}

// MARK: - City picker sheet (search-driven)

private struct CityPickerSheet: View {
    let onPick: (PinnedCity) -> Void
    @State private var search = ""
    @Environment(\.dismiss) private var dismiss

    var filtered: [PinnedCity] {
        guard !search.isEmpty else { return CityCatalog.all }
        return CityCatalog.all.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Add city").font(.headline).foregroundStyle(TallyTheme.text)
                Spacer()
                Button("Cancel") { dismiss() }
            }.padding()

            Divider()

            TextField("Search", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding()

            List(filtered) { city in
                Button {
                    // Bake the catalog city's IANA timezone identifier into
                    // the pin at the moment of picking, so the row doesn't
                    // depend on the engine's name-resolution chain at
                    // render time. Falls back to nil if the resolver
                    // doesn't know this name (extremely rare for catalog
                    // entries) — the row's `resolvedTimeZone` getter does
                    // the right thing in that case.
                    var pinned = city
                    if pinned.timeZoneId == nil {
                        pinned.timeZoneId = TimezoneBridge.resolve(city.name)?.identifier
                    }
                    onPick(pinned)
                } label: {
                    HStack {
                        Image(systemName: "mappin.circle.fill").foregroundStyle(TallyTheme.accent)
                        Text(city.name).foregroundStyle(TallyTheme.text)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(TallyTheme.background)
            }
            .scrollContentBackground(.hidden)
        }
        .frame(width: 360, height: 480)
        .themedSheet()
    }
}

// MARK: - Add-pin-from-coordinate sheet (reverse geocodes the tapped point)

private struct CoordWrapper: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D

    static func binding(_ source: Binding<CLLocationCoordinate2D?>) -> Binding<CoordWrapper?> {
        Binding(
            get: { source.wrappedValue.map { CoordWrapper(coordinate: $0) } },
            set: { source.wrappedValue = $0?.coordinate }
        )
    }
}

private struct AddPinFromCoordSheet: View {
    let coordinate: CLLocationCoordinate2D
    let onFinish: (PinnedCity?) -> Void

    @State private var resolvedName: String = "…"
    @State private var resolvedTZId: String? = nil
    @State private var customName: String = ""
    @State private var isResolving = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pin this location").font(.headline).foregroundStyle(TallyTheme.text)
            Text(String(format: "%.4f, %.4f", coordinate.latitude, coordinate.longitude))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(TallyTheme.muted)

            HStack {
                Text("Name").frame(width: 60, alignment: .leading).foregroundStyle(TallyTheme.text)
                TextField("e.g. Canggu", text: $customName,
                          prompt: Text(isResolving ? "Resolving…" : resolvedName))
                    .textFieldStyle(.roundedBorder)
            }
            // Surface the detected timezone so the user can see at the
            // sheet what they'll get — saves a "why does this read —?"
            // round-trip after adding.
            if let id = resolvedTZId, let tz = TimeZone(identifier: id) {
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .foregroundStyle(TallyTheme.muted)
                    Text(id)
                        .font(.caption)
                        .foregroundStyle(TallyTheme.muted)
                    Text("·")
                        .foregroundStyle(TallyTheme.muted)
                    Text(timeString(in: tz))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(TallyTheme.text)
                }
                .padding(.leading, 60)
            }
            HStack {
                Spacer()
                Button("Cancel") { onFinish(nil) }
                Button("Add pin") {
                    let name = customName.trimmingCharacters(in: .whitespaces)
                    let finalName = name.isEmpty ? resolvedName : name
                    onFinish(PinnedCity(name: finalName,
                                        latitude: coordinate.latitude,
                                        longitude: coordinate.longitude,
                                        timeZoneId: resolvedTZId))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isResolving)
            }
        }
        .padding(20)
        .frame(width: 380)
        .themedSheet()
        .task {
            let geocoder = CLGeocoder()
            let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            if let placemarks = try? await geocoder.reverseGeocodeLocation(location),
               let p = placemarks.first {
                resolvedName = p.locality
                    ?? p.subAdministrativeArea
                    ?? p.administrativeArea
                    ?? p.country
                    ?? "Unknown"
                // Placemarks carry an IANA timezone — capture it so the
                // pinned row can show a live clock without us having to
                // round-trip through the name resolver.
                resolvedTZId = p.timeZone?.identifier
            } else {
                resolvedName = "Unknown"
            }
            isResolving = false
        }
    }

    private func timeString(in tz: TimeZone) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "HH:mm"
        fmt.timeZone = tz
        return "\(fmt.string(from: Date())) local"
    }
}

// MARK: - MapKit host with day/night curve overlay + tap recognition

private struct MapWithDayNight: NSViewRepresentable {
    let cities: [PinnedCity]
    let terminator: [CLLocationCoordinate2D]
    let onTap: (CLLocationCoordinate2D) -> Void

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsCompass = false
        map.isPitchEnabled = false
        let initial = MKCoordinateRegion(
            center: .init(latitude: 20, longitude: 0),
            span: .init(latitudeDelta: 140, longitudeDelta: 360)
        )
        map.setRegion(initial, animated: false)

        let click = NSClickGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleClick(_:))
        )
        click.numberOfClicksRequired = 1
        click.buttonMask = 0x1
        click.delaysPrimaryMouseButtonEvents = false
        map.addGestureRecognizer(click)
        context.coordinator.map = map
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        // Refresh pins
        map.removeAnnotations(map.annotations)
        for city in cities {
            let pin = MKPointAnnotation()
            pin.coordinate = .init(latitude: city.latitude, longitude: city.longitude)
            pin.title = city.name
            map.addAnnotation(pin)
        }

        // Refresh terminator overlay
        map.removeOverlays(map.overlays)
        if terminator.count > 2 {
            let line = MKPolyline(coordinates: terminator, count: terminator.count)
            map.addOverlay(line, level: .aboveLabels)

            // Close the night polygon to the pole opposite the subsolar
            // latitude — when the sun is north of the equator, night
            // fills the southern half (and vice versa). Walk the closing
            // edge at the same longitude steps as the terminator so no
            // single polygon edge spans the antimeridian.
            let subsolar = DayNightCurve.subsolarPoint()
            let closingLat: CLLocationDegrees = subsolar.latitude >= 0 ? -90 : 90
            var nightCoords = terminator
            for point in terminator.reversed() {
                nightCoords.append(.init(latitude: closingLat, longitude: point.longitude))
            }
            let polygon = MKPolygon(coordinates: nightCoords, count: nightCoords.count)
            map.addOverlay(polygon, level: .aboveLabels)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }

    final class Coordinator: NSObject, MKMapViewDelegate {
        let onTap: (CLLocationCoordinate2D) -> Void
        weak var map: MKMapView?

        init(onTap: @escaping (CLLocationCoordinate2D) -> Void) { self.onTap = onTap }

        @objc func handleClick(_ recognizer: NSClickGestureRecognizer) {
            guard let map else { return }
            let point = recognizer.location(in: map)
            // If the click landed on an existing annotation view we let MapKit
            // handle it (selection); otherwise it's a "pin here" action.
            for ann in map.annotations {
                if let view = map.view(for: ann) {
                    if view.frame.contains(point) { return }
                }
            }
            let coord = map.convert(point, toCoordinateFrom: map)
            onTap(coord)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polygon = overlay as? MKPolygon {
                let renderer = MKPolygonRenderer(polygon: polygon)
                renderer.fillColor = NSColor.black.withAlphaComponent(0.28)
                renderer.strokeColor = NSColor.clear
                return renderer
            }
            if let line = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: line)
                renderer.strokeColor = NSColor.systemYellow.withAlphaComponent(0.7)
                renderer.lineWidth = 1.2
                renderer.lineDashPattern = [4, 3]
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}
