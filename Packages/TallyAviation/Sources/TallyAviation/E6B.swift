import Foundation

/// Wind triangle and airspeed conversions. All angles in degrees true unless
/// noted; the solver returns wind correction angle (WCA) signed relative to
/// the desired course.
public enum E6B {

    public struct WindSolution: Equatable, Sendable {
        /// Wind correction angle, degrees (positive = right correction).
        public let wcaDeg: Double
        /// Magnetic/true heading to fly, degrees (course + wca, normalised 0..360).
        public let headingDeg: Double
        /// Resulting ground speed, in input speed units.
        public let groundSpeed: Double
        /// Headwind component (negative = tailwind), in input speed units.
        public let headwind: Double
        /// Crosswind component (positive = from the right), in input speed units.
        public let crosswind: Double
    }

    /// Solve the wind triangle.
    /// - Parameters:
    ///   - course: desired course over the ground, degrees true.
    ///   - tas: true airspeed.
    ///   - windFromDeg: direction the wind is *coming from*, degrees true.
    ///   - windSpeed: wind speed, same units as TAS.
    public static func windTriangle(courseDeg course: Double,
                                    tas: Double,
                                    windFromDeg: Double,
                                    windSpeed: Double) -> WindSolution {
        let windAngle = ((windFromDeg - course) * .pi / 180.0)
        // Crosswind & headwind relative to course.
        let crosswind = windSpeed * sin(windAngle)
        let headwind = windSpeed * cos(windAngle)

        // WCA solved from wind triangle: sin(WCA) = crosswind / TAS.
        let sinWca = max(min(crosswind / max(tas, 0.0001), 1.0), -1.0)
        let wcaRad = asin(sinWca)
        let wcaDeg = wcaRad * 180.0 / .pi

        // Ground speed: GS = TAS·cos(WCA) − headwind component (along course).
        let gs = tas * cos(wcaRad) - headwind

        var heading = course + wcaDeg
        heading = heading.truncatingRemainder(dividingBy: 360)
        if heading < 0 { heading += 360 }

        return WindSolution(
            wcaDeg: wcaDeg,
            headingDeg: heading,
            groundSpeed: gs,
            headwind: headwind,
            crosswind: crosswind
        )
    }

    // MARK: - Airspeed conversions

    /// CAS → TAS (rule-of-thumb, ~2% per 1000 ft of pressure altitude, temp-corrected).
    /// For training/general aviation precision. Use `tasFromCAS_exact` for compressibility-accurate.
    public static func tasFromCAS(cas: Double,
                                  pressureAltitudeFt: Double,
                                  oatC: Double) -> Double {
        // Density-ratio approximation: TAS = CAS * sqrt(rho0/rho)
        // rho ratio approx from temperature & pressure altitude.
        let tK = oatC + 273.15
        let isaTK = Atmosphere.isaTempC(altitudeFt: pressureAltitudeFt) + 273.15
        let pressureRatio = pow(1 - 6.8755856e-6 * pressureAltitudeFt, 5.2558797)
        let densityRatio = pressureRatio * (isaTK / tK)
        return cas / sqrt(densityRatio)
    }

    /// Mach from TAS in knots and OAT in °C.
    public static func mach(tasKt: Double, oatC: Double) -> Double {
        let tK = oatC + 273.15
        let aKt = 38.967854 * sqrt(tK) // speed of sound in knots
        return tasKt / aKt
    }
}
