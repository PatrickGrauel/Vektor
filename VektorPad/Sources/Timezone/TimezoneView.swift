import SwiftUI

/// The Timezone pane (iPad v1) — a live list of pinned world clocks. Each
/// row shows the city's current time, UTC offset, local date with a
/// today/tomorrow/yesterday delta, and a day/night glyph. The macOS app's
/// meeting-slot scheduler and day/night map are a later pass.
struct TimezoneView: View {
    @StateObject private var store = PinnedCityStore()
    @State private var now = Date()
    @State private var showAdd = false

    // 1s tick keeps the minute rollover crisp without showing seconds.
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        List {
            ForEach(store.cities) { city in
                CityRow(city: city, now: now)
                    .listRowBackground(VektorTheme.surface.opacity(0.5))
            }
            .onDelete { store.remove(atOffsets: $0) }
            .onMove { store.move(fromOffsets: $0, toOffset: $1) }
        }
        .scrollContentBackground(.hidden)
        .background(VektorTheme.background)
        .navigationTitle("Timezone")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { EditButton() }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showAdd = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add city")
            }
        }
        .sheet(isPresented: $showAdd) { AddCitySheet(store: store) }
        .onReceive(tick) { now = $0 }
    }
}

private struct CityRow: View {
    let city: PinnedCity
    let now: Date

    var body: some View {
        let info = TimeInfo(city: city, now: now)
        HStack(spacing: 14) {
            Image(systemName: info.isDaytime ? "sun.max.fill" : "moon.stars.fill")
                .font(.system(size: 18))
                .foregroundStyle(info.isDaytime ? VektorTheme.accent : VektorTheme.muted)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(city.name)
                    .font(.headline)
                    .foregroundStyle(VektorTheme.text)
                Text(info.zoneLabel)
                    .font(.caption)
                    .foregroundStyle(VektorTheme.muted)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(info.time)
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(VektorTheme.accent)
                Text(info.dateLine)
                    .font(.caption)
                    .foregroundStyle(VektorTheme.muted)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Pure formatting for one city at an instant — time, zone label, relative
/// day, and day/night state.
private struct TimeInfo {
    let time: String
    let zoneLabel: String
    let dateLine: String
    let isDaytime: Bool

    init(city: PinnedCity, now: Date) {
        let tz = city.timeZone

        let timeFmt = DateFormatter()
        timeFmt.timeZone = tz
        timeFmt.dateFormat = "HH:mm"
        time = timeFmt.string(from: now)

        // UTC offset label.
        let secs = tz.secondsFromGMT(for: now)
        let hours = secs / 3600
        let mins = abs(secs / 60) % 60
        let offset = mins == 0
            ? String(format: "GMT%+d", hours)
            : String(format: "GMT%+d:%02d", hours, mins)

        // Pair with the abbreviation, unless the abbreviation is itself
        // offset-style (e.g. "GMT+2") — then the offset alone is enough.
        let abbr = tz.abbreviation(for: now) ?? ""
        if abbr.isEmpty || abbr.hasPrefix("GMT") || abbr.hasPrefix("+") || abbr.hasPrefix("-") {
            zoneLabel = offset
        } else {
            zoneLabel = "\(abbr) · \(offset)"
        }

        // Local hour for the day/night glyph.
        var cityCal = Calendar(identifier: .gregorian)
        cityCal.timeZone = tz
        let hour = cityCal.component(.hour, from: now)
        isDaytime = (6..<19).contains(hour)

        // Relative-day delta: take the civil (y/m/d) date in each zone at
        // this instant, rebuild both as midnight-UTC dates, and diff in
        // whole days. `ordinality(.day, in: .era)` proved unreliable here.
        var localCal = Calendar(identifier: .gregorian)
        localCal.timeZone = .current
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? tz
        let cityComps = cityCal.dateComponents([.year, .month, .day], from: now)
        let localComps = localCal.dateComponents([.year, .month, .day], from: now)
        let delta: Int = {
            guard let c = utc.date(from: cityComps), let l = utc.date(from: localComps) else { return 0 }
            return utc.dateComponents([.day], from: l, to: c).day ?? 0
        }()

        let dayFmt = DateFormatter()
        dayFmt.timeZone = tz
        dayFmt.dateFormat = "EEE d MMM"
        let dayStr = dayFmt.string(from: now)
        switch delta {
        case 0:  dateLine = "Today · \(dayStr)"
        case 1:  dateLine = "Tomorrow · \(dayStr)"
        case -1: dateLine = "Yesterday · \(dayStr)"
        default: dateLine = "\(delta > 0 ? "+" : "")\(delta)d · \(dayStr)"
        }
    }
}

/// Searchable catalog picker presented as a sheet.
private struct AddCitySheet: View {
    @ObservedObject var store: PinnedCityStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List(CityCatalog.search(query)) { city in
                Button {
                    store.add(city)
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(city.name).foregroundStyle(VektorTheme.text)
                            Text(city.country).font(.caption).foregroundStyle(VektorTheme.muted)
                        }
                        Spacer()
                        Text(abbrev(for: city)).font(.caption).foregroundStyle(VektorTheme.muted)
                    }
                }
                .listRowBackground(VektorTheme.surface.opacity(0.5))
            }
            .scrollContentBackground(.hidden)
            .background(VektorTheme.background)
            .navigationTitle("Add city")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search cities")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(VektorTheme.accent)
    }

    private func abbrev(for city: CatalogCity) -> String {
        (TimeZone(identifier: city.timeZoneId) ?? .current).abbreviation(for: Date()) ?? ""
    }
}
