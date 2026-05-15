import SwiftUI
import AppKit
import CoreLocation
import EventKit
import MapKit

// MARK: - Multi-city time strip
//
// Horizontal hour gauge with one row per pinned city. Working-hour cells
// are highlighted in the brand accent; outside-hour cells are dimmed.
// A draggable cursor lets the user scrub a proposed meeting time across
// all locations at once — the killer feature for cross-tz scheduling.
//
// Rendered as a single `Canvas` so we can hit thousands of cells without
// SwiftUI re-layout overhead. The cursor binding is a normal `@Binding`
// so the rest of the pane (converter, copy-snippet, calendar event) all
// agree on what time is selected.

struct TimeStripView: View {
    let cities: [PinnedCity]
    @Binding var cursor: Date
    /// Reorder callback. Invoked when the user drops one row onto
    /// another. Arguments follow `Array.move(fromOffsets:toOffset:)`
    /// semantics — `to` is the destination index expressed in terms
    /// of the post-removal array. Optional so callers without a
    /// mutable store (previews, tests) can omit it.
    var onMove: ((Int, Int) -> Void)? = nil

    /// Half-day of hours either side of the cursor. 12 hours either side
    /// covers a 25-cell strip, which fits a "morning here, evening there"
    /// case without scrolling.
    private let hoursEachSide: Int = 12
    private var totalHours: Int { hoursEachSide * 2 + 1 }

    /// Cursor anchored at drag-start so each onChanged sets `cursor` to
    /// `start + delta` rather than additively shifting on every callback.
    @State private var dragStartCursor: Date? = nil

    /// Width of the leading label column. Kept as a constant so the
    /// hour header above can use the same offset for its axis — without
    /// it, the header's hour ticks and cursor line drift to the left of
    /// the strip below (the header took the full row width, while each
    /// city's strip lived inside a GeometryReader that started after the
    /// label column).
    private static let labelColumnWidth: CGFloat = 130
    private static let labelStripGap: CGFloat = 8
    private static let outerPadding: CGFloat = 8

    var body: some View {
        VStack(spacing: 0) {
            // Header row: hour ticks aligned to the strip below. The
            // leading `Color.clear` reserves the same 130 + 8 pt of
            // space that each city's label column eats below, so the
            // hour ticks and the cursor line in the header sit in the
            // identical x-frame as the squares in every row.
            HStack(spacing: Self.labelStripGap) {
                Color.clear.frame(width: Self.labelColumnWidth)
                GeometryReader { geo in
                    hourHeader(width: geo.size.width)
                }
                .frame(height: 22)
            }
            .padding(.horizontal, Self.outerPadding)

            ForEach(cities) { city in
                cityRow(city: city)
                    .frame(height: 28)
                    .draggable(city.id.uuidString) {
                        Text(city.name)
                            .font(.system(.body, design: .default))
                            .foregroundStyle(TallyTheme.text)
                            .padding(6)
                            .background(TallyTheme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .dropDestination(for: String.self) { items, _ in
                        handleDrop(items, onto: city)
                    }
            }
        }
        .padding(.vertical, 4)
        .background(TallyTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// Resolve a drop onto `target` from one or more dragged UUIDs.
    /// Returns true if the model was reordered. The reorder call uses
    /// SwiftUI's onMove insertion-point convention: when dragging
    /// downwards (source index < target), the destination is `target +
    /// 1` because the source's removal shifts the target one slot up.
    private func handleDrop(_ items: [String], onto target: PinnedCity) -> Bool {
        guard let raw = items.first,
              let sourceID = UUID(uuidString: raw),
              let sourceIdx = cities.firstIndex(where: { $0.id == sourceID }),
              let targetIdx = cities.firstIndex(where: { $0.id == target.id }),
              sourceIdx != targetIdx,
              let onMove
        else { return false }
        let destination = targetIdx > sourceIdx ? targetIdx + 1 : targetIdx
        onMove(sourceIdx, destination)
        return true
    }

    // MARK: - Hour header

    private func hourHeader(width: CGFloat) -> some View {
        Canvas { ctx, size in
            let cellW = size.width / CGFloat(totalHours)
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone.current
            for i in 0..<totalHours {
                let date = cal.date(byAdding: .hour, value: i - hoursEachSide, to: cursor) ?? cursor
                let comp = cal.dateComponents([.hour], from: date)
                let h = comp.hour ?? 0
                let x = CGFloat(i) * cellW
                // Only label every 3 hours to keep the header readable.
                if h % 3 == 0 {
                    let text = Text(String(format: "%02d", h))
                        .font(.caption2)
                        .foregroundStyle(TallyTheme.muted)
                    ctx.draw(text, at: CGPoint(x: x + cellW / 2, y: 11))
                }
            }
            // Cursor line on the header too, so the user can see where
            // they're scrubbing.
            let cursorX = size.width / 2
            var line = Path()
            line.move(to: CGPoint(x: cursorX, y: 0))
            line.addLine(to: CGPoint(x: cursorX, y: size.height))
            ctx.stroke(line, with: .color(TallyTheme.accent), lineWidth: 1)
        }
        .frame(width: width)
    }

    // MARK: - Per-city row

    private func cityRow(city: PinnedCity) -> some View {
        HStack(spacing: 8) {
            // Left label column
            VStack(alignment: .leading, spacing: 0) {
                Text(city.name)
                    .font(.system(.body, design: .default))
                    .foregroundStyle(TallyTheme.text)
                    .lineLimit(1)
                Text(localTime(for: city, at: cursor))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(TallyTheme.muted)
            }
            .frame(width: 130, alignment: .leading)

            // Strip
            GeometryReader { geo in
                cityStrip(city: city, width: geo.size.width)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { drag in
                                // Click-to-jump (tiny translation) snaps the
                                // cursor to the hour under the pointer.
                                // Larger drags scrub continuously from the
                                // pre-drag cursor position.
                                if dragStartCursor == nil {
                                    dragStartCursor = cursor
                                }
                                let cellW = geo.size.width / CGFloat(totalHours)
                                if abs(drag.translation.width) < 4 {
                                    // Treat as a click on the cell at drag.location.x
                                    let cellIndex = Int(drag.location.x / cellW) - hoursEachSide
                                    setCursor(byHours: cellIndex)
                                } else {
                                    let hours = Int((drag.translation.width / cellW).rounded())
                                    setCursor(byHours: hours)
                                }
                            }
                            .onEnded { _ in
                                dragStartCursor = nil
                            }
                    )
            }
        }
        .padding(.horizontal, 8)
    }

    /// Shift `cursor` by `hours` relative to the value at drag-start.
    private func setCursor(byHours hours: Int) {
        guard let start = dragStartCursor else { return }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        if let new = cal.date(byAdding: .hour, value: hours, to: start) {
            cursor = new
        }
    }

    private func cityStrip(city: PinnedCity, width: CGFloat) -> some View {
        Canvas { ctx, size in
            let cellW = size.width / CGFloat(totalHours)
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone.current
            for i in 0..<totalHours {
                let date = cal.date(byAdding: .hour, value: i - hoursEachSide, to: cursor) ?? cursor
                let inHours = city.isWorkingHour(date)
                let asleep = isSleepHour(city: city, at: date)
                let fill: Color
                if inHours        { fill = TallyTheme.accent.opacity(0.55) }
                else if asleep    { fill = TallyTheme.codeSurface.opacity(0.9) }
                else              { fill = TallyTheme.surface.opacity(0.6) }
                let rect = CGRect(x: CGFloat(i) * cellW, y: 0,
                                  width: cellW, height: size.height)
                ctx.fill(Path(rect.insetBy(dx: 0.5, dy: 2)), with: .color(fill))
            }
            // Cursor line
            let cursorX = size.width / 2
            var line = Path()
            line.move(to: CGPoint(x: cursorX, y: 0))
            line.addLine(to: CGPoint(x: cursorX, y: size.height))
            ctx.stroke(line, with: .color(TallyTheme.accent), lineWidth: 2)
        }
        .frame(width: width)
        .accessibilityElement()
        .accessibilityLabel("\(city.name) hour strip")
        .accessibilityValue(localTime(for: city, at: cursor))
    }

    // MARK: - Helpers

    /// Format the cursor moment in the city's local time.
    private func localTime(for city: PinnedCity, at date: Date) -> String {
        guard let tz = city.resolvedTimeZone else { return "—" }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "EEE HH:mm zzz"
        fmt.timeZone = tz
        return fmt.string(from: date)
    }

    /// Treat 00:00–06:00 local as "asleep" for shading purposes (separate
    /// visual tier from "out of working hours but reasonable", which is
    /// e.g. 07:00–09:00 or 18:00–22:00).
    private func isSleepHour(city: PinnedCity, at date: Date) -> Bool {
        guard let tz = city.resolvedTimeZone else { return false }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let h = cal.dateComponents([.hour], from: date).hour ?? 0
        return h < 7 || h >= 22
    }

}

// MARK: - Snippet formatter
//
// Builds a copy-ready string for emails/Slack:
//
//   Tue 16 Apr · 14:00 CET / 08:00 EST / 21:00 JST
//
// Caller decides which cities to include. Times come from each city's
// resolved timezone; first city is the "source" and shown without
// parens.

enum SchedulingSnippet {

    static func format(_ cities: [PinnedCity], at date: Date) -> String {
        guard !cities.isEmpty else { return "" }

        let headerFmt = DateFormatter()
        headerFmt.locale = Locale(identifier: "en_US_POSIX")
        headerFmt.dateFormat = "EEE d MMM"
        headerFmt.timeZone = cities.first?.resolvedTimeZone ?? .current

        let timeFmt = DateFormatter()
        timeFmt.locale = Locale(identifier: "en_US_POSIX")
        timeFmt.dateFormat = "HH:mm zzz"

        let header = headerFmt.string(from: date)
        let times = cities.compactMap { city -> String? in
            guard let tz = city.resolvedTimeZone else { return nil }
            timeFmt.timeZone = tz
            return "\(city.name) \(timeFmt.string(from: date))"
        }
        return header + " · " + times.joined(separator: " / ")
    }
}

// MARK: - DST detection

enum DSTDetector {

    /// Returns the next DST transition within `days` of `from` for any
    /// supplied timezone. nil if none apply (locations don't observe DST
    /// or no transition in window).
    static func upcomingTransition(in cities: [PinnedCity],
                                   from anchor: Date,
                                   within days: Int = 28) -> (city: PinnedCity, at: Date)? {
        let window = anchor.addingTimeInterval(Double(days) * 86400)
        var soonest: (PinnedCity, Date)? = nil
        for city in cities {
            guard let tz = city.resolvedTimeZone else { continue }
            guard let transition = tz.nextDaylightSavingTimeTransition(after: anchor),
                  transition <= window
            else { continue }
            if let current = soonest {
                if transition < current.1 { soonest = (city, transition) }
            } else {
                soonest = (city, transition)
            }
        }
        return soonest
    }
}

// MARK: - Working-hours editor sheet

struct WorkingHoursEditor: View {
    @Binding var city: PinnedCity
    let onClose: () -> Void

    @State private var startHour: Int
    @State private var endHour: Int
    @State private var workDays: Set<Int>

    init(city: Binding<PinnedCity>, onClose: @escaping () -> Void) {
        self._city = city
        self.onClose = onClose
        self._startHour = State(initialValue: city.wrappedValue.workStartHour)
        self._endHour   = State(initialValue: city.wrappedValue.workEndHour)
        self._workDays  = State(initialValue: Set(city.wrappedValue.workDays))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Working hours for \(city.name)")
                .font(.headline)
                .foregroundStyle(TallyTheme.text)

            HStack(spacing: 8) {
                Text("From").frame(width: 50, alignment: .leading)
                    .foregroundStyle(TallyTheme.muted)
                Picker("", selection: $startHour) {
                    ForEach(0..<24, id: \.self) { h in
                        Text(String(format: "%02d:00", h)).tag(h)
                    }
                }
                .labelsHidden()
                .frame(width: 100)
                Text("to")
                    .foregroundStyle(TallyTheme.muted)
                Picker("", selection: $endHour) {
                    ForEach(1...24, id: \.self) { h in
                        Text(String(format: "%02d:00", h)).tag(h)
                    }
                }
                .labelsHidden()
                .frame(width: 100)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Workdays").font(.caption).foregroundStyle(TallyTheme.muted)
                HStack(spacing: 4) {
                    ForEach(WorkingHoursEditor.dayLabels.enumerated().map { $0 }, id: \.offset) { offset, label in
                        let weekday = offset + 1     // Sun=1 … Sat=7
                        Toggle(isOn: Binding(
                            get: { workDays.contains(weekday) },
                            set: { on in
                                if on { workDays.insert(weekday) }
                                else  { workDays.remove(weekday) }
                            }
                        )) {
                            Text(label)
                                .font(.caption)
                                .frame(width: 28)
                        }
                        .toggleStyle(.button)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { onClose() }
                Button("Save") {
                    city.workStartHour = startHour
                    city.workEndHour = max(endHour, startHour + 1)
                    city.workDays = Array(workDays).sorted()
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .themedSheet()
    }

    private static let dayLabels = ["S", "M", "T", "W", "T", "F", "S"]
}

// MARK: - Place search sheet (MapKit-backed)
//
// Backed by `MKLocalSearchCompleter` (the same engine Apple Maps uses
// for the search bar) for instant as-you-type suggestions, then
// `MKLocalSearch` to resolve the chosen completion into a coordinate +
// IANA timezone. Handles real points-of-interest like "Uluwatu",
// "Schmidsdorf", "Sagrada Família" — anything the Maps app would find —
// not just street addresses, which is what the old CLGeocoder fallback
// was limited to.

@MainActor
final class PlaceSearchModel: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var completions: [MKLocalSearchCompletion] = []
    @Published var query: String = "" {
        didSet {
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                completions = []
                completer.cancel()
            } else {
                completer.queryFragment = trimmed
            }
        }
    }
    @Published var resolving: Bool = false
    @Published var errorMessage: String? = nil

    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        // Accept both addresses AND points of interest — the key fix
        // versus CLGeocoder, which couldn't find named landmarks /
        // surf breaks / café districts like "Uluwatu".
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func clear() {
        query = ""
        completions = []
        errorMessage = nil
    }

    /// Turn a tapped completion into a fully-formed PinnedCity by
    /// running an MKLocalSearch on it — that's the only way to get a
    /// real coordinate + a `placemark.timeZone` back. Returns nil if
    /// the search yields nothing actionable.
    ///
    /// MKMapItem's placemark sometimes lacks a `timeZone` (small POIs,
    /// beach landmarks, boutique businesses), even though the
    /// coordinate is fine. When that happens we re-geocode the
    /// coordinate via CLGeocoder, whose placemark *does* carry a
    /// timezone for most populated places. Without this fallback the
    /// city ends up with a nil `timeZoneId` and every downstream
    /// feature — strip row, best slots, converter — silently treats
    /// it as a "—".
    func resolve(_ completion: MKLocalSearchCompletion) async -> PinnedCity? {
        resolving = true
        defer { resolving = false }
        let request = MKLocalSearch.Request(completion: completion)
        do {
            let response = try await MKLocalSearch(request: request).start()
            guard let item = response.mapItems.first else { return nil }
            let coord = item.placemark.coordinate
            let name = (item.name?.isEmpty == false ? item.name! : completion.title)
            var tzId = item.placemark.timeZone?.identifier

            if tzId == nil {
                tzId = await reverseGeocodeTimeZone(at: coord)
            }

            return PinnedCity(
                name: name,
                latitude: coord.latitude,
                longitude: coord.longitude,
                timeZoneId: tzId
            )
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Use CLGeocoder's reverse-geocode as a timezone-resolution
    /// fallback. CLGeocoder returns CLPlacemarks whose `timeZone`
    /// property is populated for nearly all populated locations.
    private func reverseGeocodeTimeZone(at coord: CLLocationCoordinate2D) async -> String? {
        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        guard let placemarks = try? await geocoder.reverseGeocodeLocation(location),
              let p = placemarks.first
        else { return nil }
        return p.timeZone?.identifier
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results
        Task { @MainActor in
            self.completions = results
            self.errorMessage = nil
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter,
                               didFailWithError error: Error) {
        Task { @MainActor in
            self.completions = []
            self.errorMessage = (error as NSError).localizedDescription
        }
    }
}

struct PlaceSearchSheet: View {
    let onPick: (PinnedCity) -> Void
    let onCancel: () -> Void

    @StateObject private var model = PlaceSearchModel()
    @FocusState private var focused: Bool

    /// Quick-pick chips shown when the search field is empty. Each is a
    /// real, geocodable example that proves the search works for places
    /// the old catalog could never have known about.
    private let examples = ["Uluwatu, Bali", "Chiang Mai", "Buenos Aires",
                            "Marrakech", "Reykjavík", "6th arr. Paris"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            searchField

            if model.query.isEmpty {
                exampleChips
            } else if !model.completions.isEmpty {
                resultsList
            } else if let err = model.errorMessage {
                errorRow(err)
            } else {
                Text("Type to search worldwide — addresses, cities, neighbourhoods, POIs.")
                    .font(.caption)
                    .foregroundStyle(TallyTheme.muted)
                    .padding(.vertical, 4)
            }

            Spacer(minLength: 0)

            HStack {
                if model.resolving {
                    ProgressView().controlSize(.small)
                    Text("Resolving…")
                        .font(.caption)
                        .foregroundStyle(TallyTheme.muted)
                }
                Spacer()
                Button("Cancel") { onCancel() }
            }
        }
        .padding(20)
        .frame(width: 520, height: 460)
        .themedSheet()
        .onAppear { focused = true }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Add a place").font(.headline).foregroundStyle(TallyTheme.text)
            Text("Powered by Apple Maps — finds POIs, neighbourhoods, regions, and addresses.")
                .font(.caption)
                .foregroundStyle(TallyTheme.muted)
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(TallyTheme.muted)
            TextField("Try “Uluwatu” or “Tokyo” or “3 rue de Rivoli”",
                      text: $model.query)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit {
                    // Pressing return picks the first suggestion if any.
                    if let first = model.completions.first {
                        Task { await pick(first) }
                    }
                }
            if !model.query.isEmpty {
                Button {
                    model.clear()
                    focused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(TallyTheme.muted)
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(8)
        .background(TallyTheme.codeSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var exampleChips: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Try")
                .font(.caption.weight(.semibold))
                .foregroundStyle(TallyTheme.muted)
            FlowLayout(spacing: 8) {
                ForEach(examples, id: \.self) { example in
                    Button {
                        model.query = example
                    } label: {
                        Text(example)
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(TallyTheme.surface)
                            .foregroundStyle(TallyTheme.text)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var resultsList: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(model.completions, id: \.self) { c in
                    Button {
                        Task { await pick(c) }
                    } label: {
                        HStack(alignment: .center, spacing: 10) {
                            Image(systemName: iconFor(c))
                                .foregroundStyle(TallyTheme.accent)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(c.title)
                                    .foregroundStyle(TallyTheme.text)
                                if !c.subtitle.isEmpty {
                                    Text(c.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(TallyTheme.muted)
                                }
                            }
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.caption)
                                .foregroundStyle(TallyTheme.muted)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(TallyTheme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxHeight: 280)
    }

    private func errorRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(TallyTheme.statusCaution)
            VStack(alignment: .leading, spacing: 2) {
                Text("Search failed")
                    .foregroundStyle(TallyTheme.text)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    /// Crude heuristic to pick a glyph that matches the kind of result.
    /// MKLocalSearchCompletion doesn't expose a category directly, so we
    /// infer from the subtitle being empty (POI) vs. populated (address).
    private func iconFor(_ c: MKLocalSearchCompletion) -> String {
        if c.subtitle.isEmpty {
            return "mappin.circle.fill"
        }
        return "globe"
    }

    private func pick(_ completion: MKLocalSearchCompletion) async {
        if let city = await model.resolve(completion) {
            onPick(city)
        }
    }
}

// MARK: - Tiny flow layout (for chip wrap)
//
// SwiftUI's `Grid` and `HStack` don't wrap. We need a one-line custom
// `Layout` so the example chips wrap to the next line gracefully when
// the sheet is narrower than the chips' total width.

private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var width: CGFloat = 0
        var height: CGFloat = 0
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0
        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if lineWidth + size.width > maxWidth {
                width = max(width, lineWidth)
                height += lineHeight + spacing
                lineWidth = size.width
                lineHeight = size.height
            } else {
                lineWidth += (lineWidth == 0 ? 0 : spacing) + size.width
                lineHeight = max(lineHeight, size.height)
            }
        }
        width = max(width, lineWidth)
        height += lineHeight
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var lineHeight: CGFloat = 0
        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + maxWidth {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            sv.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - EventKit "Add to Calendar"
//
// Saves a fully-formed event with title, target calendar, duration,
// alarm, location, URL, and an auto-generated cross-timezone notes
// blob. Optionally opens Apple Calendar at the event's date so the
// user can add attendees (the public EventKit API doesn't permit
// programmatic attendee insertion — that has to happen in the host
// Calendar UI).

struct CalendarSaveOptions: Equatable {
    var title: String
    /// Absolute start moment chosen in the confirm sheet. The cursor
    /// seeds it, but the user can override (and the picker snaps to
    /// 15-min slots so the calendar never sees a 13:32).
    var startsAt: Date
    var durationMinutes: Int
    var location: String
    var url: URL?
    /// Minutes-before-start to fire an alarm. `-1` means no alarm,
    /// `0` means "at start time".
    var alarmMinutes: Int
    /// Target calendar identifier; nil = system default.
    var calendarID: String?
    /// Whether to open Calendar.app after saving.
    var openInCalendar: Bool
}

@MainActor
enum CalendarExporter {

    enum Outcome {
        case created
        case denied
        case error(String)
    }

    /// Ask for full event-store access, returning nothing if denied.
    static func loadWritableCalendars() async -> ([EKCalendar], defaultID: String?) {
        let store = EKEventStore()
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        guard granted else { return ([], nil) }
        let writable = store.calendars(for: .event).filter { $0.allowsContentModifications }
        return (writable, store.defaultCalendarForNewEvents?.calendarIdentifier)
    }

    static func create(date: Date,
                       notes: String,
                       options: CalendarSaveOptions) async -> Outcome {
        let store = EKEventStore()
        let granted: Bool
        do {
            granted = try await store.requestFullAccessToEvents()
        } catch {
            return .error(error.localizedDescription)
        }
        guard granted else { return .denied }

        let event = EKEvent(eventStore: store)
        event.title = options.title.trimmingCharacters(in: .whitespaces).isEmpty
            ? "Meeting"
            : options.title
        event.startDate = date
        event.endDate = date.addingTimeInterval(TimeInterval(options.durationMinutes) * 60)
        if !options.location.isEmpty { event.location = options.location }
        if let url = options.url { event.url = url }
        event.notes = notes

        // Alarm (offset is negative = before start).
        if options.alarmMinutes >= 0 {
            let offset = -TimeInterval(options.alarmMinutes * 60)
            event.alarms = [EKAlarm(relativeOffset: offset)]
        }

        // Calendar pick (fallback to default).
        if let calID = options.calendarID,
           let cal = store.calendar(withIdentifier: calID),
           cal.allowsContentModifications {
            event.calendar = cal
        } else {
            event.calendar = store.defaultCalendarForNewEvents
        }

        do {
            try store.save(event, span: .thisEvent)
        } catch {
            return .error(error.localizedDescription)
        }

        if options.openInCalendar {
            openCalendarApp(at: date)
        }
        return .created
    }

    /// Jump Calendar.app to the event's day. Apple's `calshow:` URL
    /// scheme accepts seconds since reference date (2001-01-01 UTC) —
    /// no documented programmatic way to select a specific event, but
    /// landing on the right day is enough for the user to find it.
    static func openCalendarApp(at date: Date) {
        let seconds = Int(date.timeIntervalSinceReferenceDate)
        if let url = URL(string: "calshow:\(seconds)") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Calendar confirm sheet
//
// Full-featured save dialog. Lets the user pick:
//   – Title (persisted across launches)
//   – Target calendar (Work / Personal / etc., loaded via EventKit)
//   – Duration (preset picker, with a Custom-minutes escape hatch)
//   – Alert lead time (None / 5 / 10 / 15 / 30 / 60 min)
//   – Location (room / address)
//   – URL (separate field — Calendar renders this as a clickable link)
//   – "Open in Calendar after saving" — for adding attendees, since
//     EventKit's public API doesn't permit programmatic attendee
//     inserts on macOS
// And shows the cursor moment in every pinned city's local time so
// there's no ambiguity about which day/hour gets saved.

struct CalendarConfirmSheet: View {
    let cursor: Date
    let cities: [PinnedCity]
    let onConfirm: (CalendarSaveOptions) -> Void
    let onCancel: () -> Void

    @AppStorage("tally.calendar.lastTitle")      private var lastTitle: String = "Sync"
    @AppStorage("tally.calendar.lastDuration")   private var lastDuration: Int = 60
    @AppStorage("tally.calendar.lastAlarm")      private var lastAlarm: Int = 10
    @AppStorage("tally.calendar.lastCalendarID") private var lastCalendarID: String = ""
    @AppStorage("tally.calendar.openAfterSave")  private var openAfterSave: Bool = false

    @State private var title: String = ""
    @State private var duration: Int = 60
    @State private var customDuration: Bool = false
    @State private var alarmMinutes: Int = 10
    @State private var location: String = ""
    @State private var urlString: String = ""
    @State private var calendars: [EKCalendar] = []
    @State private var selectedCalendarID: String = ""
    @State private var permissionDenied: Bool = false
    @State private var loading: Bool = true
    /// Date component of the start moment. Time stripped — slot picker
    /// supplies the time-of-day so we never have to snap minutes.
    @State private var startDay: Date = Date()
    /// Index into the 15-min slot grid: 0 = 00:00, 1 = 00:15, … 95 = 23:45.
    @State private var startSlotIndex: Int = 0

    @FocusState private var focused: Field?

    enum Field: Hashable { case title, location, url }

    /// Total number of 15-min slots in a day (24 × 4).
    private static let slotCount = 96

    private static func slotLabel(_ index: Int) -> String {
        let total = index * 15
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private static let presetDurations: [Int] = [15, 30, 45, 60, 90, 120]
    private static let alarmOptions: [(label: String, minutes: Int)] = [
        ("None",          -1),
        ("At start time",  0),
        ("5 min before",   5),
        ("10 min before", 10),
        ("15 min before", 15),
        ("30 min before", 30),
        ("1 hr before",   60),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 10) {
                titleRow
                calendarRow
                startRow
                durationRow
                alarmRow
                locationRow
                urlRow
            }

            notesPreview

            Toggle("Open in Calendar after saving (to add attendees)",
                   isOn: $openAfterSave)
                .toggleStyle(.checkbox)
                .font(.caption)
                .foregroundStyle(TallyTheme.muted)

            if permissionDenied {
                permissionRow
            }

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                Button("Save") { saveAction() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saveDisabled)
            }
        }
        .padding(20)
        .frame(width: 560)
        .themedSheet()
        .task { await initialise() }
    }

    // MARK: - Subviews

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Save meeting to Calendar")
                .font(.headline)
                .foregroundStyle(TallyTheme.text)
            Text("Adds a fully-formed event with title, duration, alert, and the cross-timezone note.")
                .font(.caption)
                .foregroundStyle(TallyTheme.muted)
        }
    }

    private var titleRow: some View {
        GridRow {
            label("Title")
            TextField("Sync", text: $title)
                .textFieldStyle(.roundedBorder)
                .focused($focused, equals: .title)
        }
    }

    @ViewBuilder
    private var calendarRow: some View {
        GridRow {
            label("Calendar")
            if loading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading calendars…")
                        .font(.caption)
                        .foregroundStyle(TallyTheme.muted)
                }
            } else if calendars.isEmpty {
                Text("System default")
                    .font(.caption)
                    .foregroundStyle(TallyTheme.muted)
            } else {
                Picker("", selection: $selectedCalendarID) {
                    ForEach(calendars, id: \.calendarIdentifier) { cal in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color(nsColor: cal.color))
                                .frame(width: 9, height: 9)
                            Text(cal.title)
                        }
                        .tag(cal.calendarIdentifier)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 280, alignment: .leading)
            }
        }
    }

    private var startRow: some View {
        GridRow(alignment: .top) {
            label("Starts")
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    DatePicker("", selection: $startDay, displayedComponents: .date)
                        .labelsHidden()
                    Picker("", selection: $startSlotIndex) {
                        ForEach(0..<Self.slotCount, id: \.self) { i in
                            Text(Self.slotLabel(i)).tag(i)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 90)
                    .help("Quarter-hour slots — no 13:32 meetings")
                }
                ForEach(cityStarts, id: \.name) { row in
                    HStack(spacing: 6) {
                        Text(row.name)
                            .frame(width: 110, alignment: .leading)
                            .foregroundStyle(TallyTheme.muted)
                        Text(row.line)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(TallyTheme.text)
                        if let delta = row.delta {
                            Text(delta)
                                .font(.caption2)
                                .foregroundStyle(TallyTheme.accent)
                        }
                    }
                }
            }
        }
    }

    private var durationRow: some View {
        GridRow {
            label("Duration")
            HStack(spacing: 8) {
                if customDuration {
                    TextField("", value: $duration, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    Text("min").foregroundStyle(TallyTheme.muted)
                    Button("Use preset") { customDuration = false }
                        .buttonStyle(.borderless)
                        .font(.caption)
                } else {
                    Picker("", selection: $duration) {
                        ForEach(Self.presetDurations, id: \.self) { mins in
                            Text(durationLabel(mins)).tag(mins)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                    Button("Custom…") { customDuration = true }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
        }
    }

    private var alarmRow: some View {
        GridRow {
            label("Alert")
            Picker("", selection: $alarmMinutes) {
                ForEach(Self.alarmOptions, id: \.minutes) { opt in
                    Text(opt.label).tag(opt.minutes)
                }
            }
            .labelsHidden()
            .frame(width: 200, alignment: .leading)
        }
    }

    private var locationRow: some View {
        GridRow {
            label("Location")
            TextField("Optional — room name or address", text: $location)
                .textFieldStyle(.roundedBorder)
                .focused($focused, equals: .location)
        }
    }

    private var urlRow: some View {
        GridRow {
            label("URL")
            TextField("Optional — Zoom / Meet / Teams link", text: $urlString)
                .textFieldStyle(.roundedBorder)
                .focused($focused, equals: .url)
        }
    }

    private var notesPreview: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Notes (auto-filled)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(TallyTheme.muted)
            Text(SchedulingSnippet.format(cities, at: startsAt))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(TallyTheme.muted)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(TallyTheme.codeSurface)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    /// The chosen start: midnight of `startDay` plus `startSlotIndex` × 15 min.
    /// Computed off the user's local calendar so the time-of-day matches the
    /// labels in the slot picker.
    private var startsAt: Date {
        let cal = Calendar.current
        let day = cal.startOfDay(for: startDay)
        return cal.date(byAdding: .minute, value: startSlotIndex * 15, to: day) ?? day
    }

    private var permissionRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(TallyTheme.statusCaution)
            Text("Calendar access denied — enable Tally in System Settings → Privacy → Calendars.")
                .font(.caption)
                .foregroundStyle(TallyTheme.muted)
        }
    }

    private func label(_ s: String) -> some View {
        Text(s)
            .frame(width: 72, alignment: .leading)
            .foregroundStyle(TallyTheme.muted)
    }

    // MARK: - Data

    private var saveDisabled: Bool {
        title.trimmingCharacters(in: .whitespaces).isEmpty || duration < 1
    }

    private struct CityStart {
        let name: String
        let line: String
        let delta: String?
    }

    /// One row per pinned city showing the cursor moment in its local
    /// time, plus an optional day-delta vs the first pinned city.
    private var cityStarts: [CityStart] {
        guard let primaryTZ = cities.first?.resolvedTimeZone else { return [] }
        let moment = startsAt
        var primaryCal = Calendar(identifier: .gregorian); primaryCal.timeZone = primaryTZ
        let primaryDay = primaryCal.ordinality(of: .day, in: .era, for: moment) ?? 0

        return cities.compactMap { city in
            guard let tz = city.resolvedTimeZone else { return nil }
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.timeZone = tz
            fmt.dateFormat = "EEE HH:mm zzz"
            let line = fmt.string(from: moment)

            var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
            let day = cal.ordinality(of: .day, in: .era, for: moment) ?? 0
            let delta = day - primaryDay
            let deltaLabel: String?
            if delta == 0      { deltaLabel = nil }
            else if delta > 0  { deltaLabel = "+\(delta) day" }
            else               { deltaLabel = "\(delta) day" }
            return CityStart(name: city.name, line: line, delta: deltaLabel)
        }
    }

    /// Seed `startDay` / `startSlotIndex` from the cursor, rounding **up**
    /// to the next 15-min slot so we never propose a start that's already
    /// in the past. Overflowing past 23:45 rolls into the next day.
    private func seedStart(from moment: Date) {
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute], from: moment)
        let totalMin = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        let nextSlot = Int(ceil(Double(totalMin) / 15.0))
        if nextSlot >= Self.slotCount {
            startDay = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: moment)) ?? moment
            startSlotIndex = 0
        } else {
            startDay = cal.startOfDay(for: moment)
            startSlotIndex = nextSlot
        }
    }

    private func durationLabel(_ mins: Int) -> String {
        if mins < 60 { return "\(mins) min" }
        let h = mins / 60
        let m = mins % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    // MARK: - Actions

    private func initialise() async {
        title = lastTitle
        duration = lastDuration
        alarmMinutes = lastAlarm
        customDuration = !Self.presetDurations.contains(lastDuration)
        seedStart(from: cursor)

        let (loaded, defaultID) = await CalendarExporter.loadWritableCalendars()
        await MainActor.run {
            self.calendars = loaded
            self.loading = false
            if loaded.isEmpty {
                self.permissionDenied = true
            } else {
                let preferred = lastCalendarID.isEmpty
                    ? (defaultID ?? loaded.first?.calendarIdentifier ?? "")
                    : lastCalendarID
                self.selectedCalendarID = loaded.contains(where: { $0.calendarIdentifier == preferred })
                    ? preferred
                    : (defaultID ?? loaded.first?.calendarIdentifier ?? "")
            }
            self.focused = .title
        }
    }

    private func saveAction() {
        lastTitle = title
        lastDuration = duration
        lastAlarm = alarmMinutes
        lastCalendarID = selectedCalendarID
        let url: URL? = {
            let trimmed = urlString.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : URL(string: trimmed)
        }()
        let opts = CalendarSaveOptions(
            title: title,
            startsAt: startsAt,
            durationMinutes: duration,
            location: location,
            url: url,
            alarmMinutes: alarmMinutes,
            calendarID: selectedCalendarID.isEmpty ? nil : selectedCalendarID,
            openInCalendar: openAfterSave
        )
        onConfirm(opts)
    }
}


// MARK: - Pasteboard helper

enum Clipboard {
    static func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}
