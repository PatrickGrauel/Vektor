import Foundation
import CoreLocation

/// Computes the day-night terminator — the boundary between the sunlit and
/// dark halves of Earth — as a sequence of (lat, lon) points for plotting.
///
/// Reference: standard solar-position approximation (NOAA solar calculator).
/// Good to a few minutes of arc for visualisation purposes; not survey-grade.
enum DayNightCurve {

    /// Sample the terminator as `latitude(longitude)` across uniform
    /// longitudes from -180° to +180°. Sampling this way (instead of
    /// parametrically around the great circle in 3D) keeps consecutive
    /// points ~1° apart in projected map coordinates, so MapKit's
    /// polyline / polygon edges never self-intersect or wrap the
    /// antimeridian.
    ///
    /// Derivation: a point is on the terminator iff its angle to the
    /// subsolar point is 90°, i.e.
    ///   sin(lat)·sin(latₛ) + cos(lat)·cos(latₛ)·cos(lon − lonₛ) = 0
    /// Solving for lat gives lat = atan(−cos(lon − lonₛ) / tan(latₛ)).
    /// Degenerate at equinox (latₛ ≈ 0) where the terminator collapses
    /// to two meridians — return empty in that case rather than draw
    /// a malformed curve.
    static func points(at date: Date = Date(), samples: Int = 361) -> [CLLocationCoordinate2D] {
        let subsolar = subsolarPoint(at: date)
        let latS = subsolar.latitude * .pi / 180
        let lonS = subsolar.longitude * .pi / 180
        guard abs(latS) > 1e-3 else { return [] }
        let tanLatS = tan(latS)

        var result: [CLLocationCoordinate2D] = []
        result.reserveCapacity(samples)
        for i in 0..<samples {
            let lonDeg = -180.0 + Double(i) * 360.0 / Double(samples - 1)
            let lon = lonDeg * .pi / 180
            let lat = atan(-cos(lon - lonS) / tanLatS) * 180 / .pi
            result.append(CLLocationCoordinate2D(latitude: lat, longitude: lonDeg))
        }
        return result
    }

    /// Approximate subsolar point (lat = solar declination, lon = where the
    /// sun is overhead at this UTC instant).
    static func subsolarPoint(at date: Date = Date()) -> CLLocationCoordinate2D {
        var cal = Calendar(identifier: .gregorian)
        // Defensive: TimeZone(identifier: "UTC") effectively never returns
        // nil, but falling back to secondsFromGMT: 0 keeps us off a
        // force-unwrap on a path that runs every redraw of the day/night
        // curve.
        cal.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0) ?? .current
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        // Manual day-of-year (avoids macOS 15 dependency).
        let dayOfYear = Double(cal.ordinality(of: .day, in: .year, for: date) ?? 1)
        let utcHours = Double(comps.hour ?? 0)
            + Double(comps.minute ?? 0) / 60
            + Double(comps.second ?? 0) / 3600

        // Declination (axial tilt × yearly cosine).
        let dRad = 2.0 * .pi * (dayOfYear - 81.0) / 365.0
        let declinationDeg = 23.44 * sin(dRad)

        // Subsolar longitude: where the sun is overhead. At 12:00 UTC the
        // sun is over 0° E (roughly). Each hour shifts 15° west.
        let subsolarLonDeg = 15.0 * (12.0 - utcHours)
        // Normalize to (-180, 180]
        let lon = ((subsolarLonDeg + 540).truncatingRemainder(dividingBy: 360)) - 180

        return CLLocationCoordinate2D(latitude: declinationDeg, longitude: lon)
    }
}
