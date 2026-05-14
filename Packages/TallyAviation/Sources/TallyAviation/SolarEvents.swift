import Foundation

/// Sunrise / sunset / civil-twilight calculator.
///
/// Implements the standard sunrise equation as published by NOAA
/// (https://gml.noaa.gov/grad/solcalc/), simplified to deal with just
/// the events Tally needs: SR (sunrise, upper limb at horizon), SS
/// (sunset, same), BMNT/EECT (begin/end of civil twilight, sun 6°
/// below horizon).
///
/// Accuracy is well under a minute at latitudes < 65°. Doesn't handle
/// polar regions where the sun never rises or never sets — those
/// return `nil` for the corresponding event.
///
/// Conventions:
///   - Longitudes are EAST-positive (the usual geographic convention).
///   - `date` argument is used to extract the calendar day in UTC;
///     the times of the returned events are absolute Dates, not
///     wall-clock hours of any particular zone.
public enum SolarEvents {

    public struct Events: Sendable, Equatable {
        public let sunrise: Date?
        public let sunset: Date?
        /// Beginning of morning civil twilight (sun's centre is 6°
        /// below the horizon and rising).
        public let civilTwilightBegin: Date?
        /// End of evening civil twilight (sun's centre is 6° below
        /// the horizon and setting). In most jurisdictions "night"
        /// for VFR purposes begins here.
        public let civilTwilightEnd: Date?
    }

    /// Compute the four events for a given date at a given lat/lon.
    public static func events(date: Date = Date(),
                              latitude: Double,
                              longitude: Double) -> Events {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0) ?? .current
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        guard let y = comps.year, let m = comps.month, let d = comps.day else {
            return Events(sunrise: nil, sunset: nil,
                          civilTwilightBegin: nil, civilTwilightEnd: nil)
        }
        // Julian Day at 0h UTC of the requested date.
        let jdMidnight = julianDayAt0hUTC(year: y, month: m, day: d)

        // Standard zeniths used in this calculator:
        //   90.833° → official sunrise/sunset (accounts for solar disc
        //             radius + atmospheric refraction)
        //   96°     → end of civil twilight (sun centre 6° below horizon)
        let sr  = solarEventJD(jdMidnight: jdMidnight, lat: latitude, lon: longitude, zenith: 90.833, morning: true)
        let ss  = solarEventJD(jdMidnight: jdMidnight, lat: latitude, lon: longitude, zenith: 90.833, morning: false)
        let ctB = solarEventJD(jdMidnight: jdMidnight, lat: latitude, lon: longitude, zenith: 96.0,   morning: true)
        let ctE = solarEventJD(jdMidnight: jdMidnight, lat: latitude, lon: longitude, zenith: 96.0,   morning: false)

        return Events(
            sunrise: sr.flatMap { dateFromJD($0) },
            sunset:  ss.flatMap { dateFromJD($0) },
            civilTwilightBegin: ctB.flatMap { dateFromJD($0) },
            civilTwilightEnd:   ctE.flatMap { dateFromJD($0) }
        )
    }

    // MARK: - Sunrise equation

    /// Compute the Julian Date of a solar event (sunrise, sunset, or
    /// a twilight equivalent) on the requested date.
    ///
    /// Steps:
    ///   1. Approximate solar noon: midnight + 0.5 − lon/360.
    ///   2. Refine with equation of time (≈0.5 min worst case).
    ///   3. Sun's declination from its ecliptic longitude.
    ///   4. Hour angle H from the requested zenith; event = transit ± H/360.
    ///
    /// Returns `nil` when |cos H| > 1 (sun never reaches that zenith
    /// at that latitude on that date — polar day or polar night).
    private static func solarEventJD(jdMidnight: Double,
                                     lat: Double, lon: Double,
                                     zenith: Double,
                                     morning: Bool) -> Double? {
        // Step 1 — approximate solar noon JD.
        let jStar = jdMidnight + 0.5 - lon / 360.0
        // Step 2 — refine via equation of time.
        let n = jStar - 2451545.0
        let M = (357.5291 + 0.98560028 * n).truncatingRemainder(dividingBy: 360)
        let Mrad = M * .pi / 180
        let C = 1.9148 * sin(Mrad)
              + 0.0200 * sin(2 * Mrad)
              + 0.0003 * sin(3 * Mrad)
        let lambda = (M + C + 180 + 102.9372).truncatingRemainder(dividingBy: 360)
        let lambdaRad = lambda * .pi / 180
        let jTransit = jStar + 0.0053 * sin(Mrad) - 0.0069 * sin(2 * lambdaRad)
        // Step 3 — solar declination.
        let sinDec = sin(lambdaRad) * sin(23.4397 * .pi / 180)
        let cosDec = cos(asin(sinDec))
        // Step 4 — hour angle for the target zenith.
        let latRad = lat * .pi / 180
        let cosH = (cos(zenith * .pi / 180) - sin(latRad) * sinDec)
                 / (cos(latRad) * cosDec)
        if cosH < -1 || cosH > 1 {
            return nil
        }
        let H = acos(cosH) * 180 / .pi
        return morning ? (jTransit - H / 360.0) : (jTransit + H / 360.0)
    }

    /// Julian Day at 00:00 UTC of a Gregorian (year, month, day).
    /// Fliegel-van Flandern integer formula, returning a half-day-
    /// adjusted real number.
    private static func julianDayAt0hUTC(year: Int, month: Int, day: Int) -> Double {
        let a = (14 - month) / 12
        let y = year + 4800 - a
        let m = month + 12 * a - 3
        let jdn = day
                + (153 * m + 2) / 5
                + 365 * y
                + y / 4
                - y / 100
                + y / 400
                - 32045
        // jdn is the integer Julian Day Number at NOON UTC of the given
        // calendar day. Subtract 0.5 to get JD at the preceding 00:00
        // UTC of the same calendar day.
        return Double(jdn) - 0.5
    }

    /// Convert a Julian Date (real-valued) to a `Date`.
    private static func dateFromJD(_ jd: Double) -> Date? {
        // JD 2440587.5 = Unix epoch (1970-01-01 00:00 UTC).
        let unix = (jd - 2440587.5) * 86400.0
        guard unix.isFinite else { return nil }
        return Date(timeIntervalSince1970: unix)
    }
}
