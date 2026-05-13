import Foundation

/// International Standard Atmosphere model + derived quantities used in
/// general-aviation flight planning. All formulas reference the FAA Pilot's
/// Handbook (PHAK) Ch. 11 and standard ISA tables.
public enum Atmosphere {

    // MARK: - Constants

    /// ISA sea-level temperature, °C.
    public static let isaSeaLevelTempC: Double = 15.0
    /// ISA sea-level pressure, hPa.
    public static let isaSeaLevelPressureHPa: Double = 1013.25
    /// ISA sea-level pressure, inHg.
    public static let isaSeaLevelPressureInHg: Double = 29.92
    /// Standard lapse rate, °C per 1000 ft.
    public static let lapseRateCPer1000Ft: Double = 2.0
    /// Standard lapse rate, °C per meter.
    public static let lapseRateCPerMeter: Double = 0.0065

    // MARK: - Conversions

    public static func ftToM(_ ft: Double) -> Double { ft * 0.3048 }
    public static func mToFt(_ m: Double) -> Double { m / 0.3048 }
    public static func inHgToHPa(_ inHg: Double) -> Double { inHg * 33.8639 }
    public static func hPaToInHg(_ hPa: Double) -> Double { hPa / 33.8639 }
    public static func cToF(_ c: Double) -> Double { c * 9.0 / 5.0 + 32.0 }
    public static func fToC(_ f: Double) -> Double { (f - 32.0) * 5.0 / 9.0 }

    // MARK: - ISA

    /// ISA temperature at a given altitude (feet).
    public static func isaTempC(altitudeFt: Double) -> Double {
        isaSeaLevelTempC - (altitudeFt / 1000.0) * lapseRateCPer1000Ft
    }

    /// ISA pressure at a given altitude (feet), in hPa, using the barometric formula.
    public static func isaPressureHPa(altitudeFt: Double) -> Double {
        let altM = ftToM(altitudeFt)
        let t0K = isaSeaLevelTempC + 273.15
        let exp = 5.25588
        let ratio = 1.0 - (lapseRateCPerMeter * altM / t0K)
        return isaSeaLevelPressureHPa * pow(ratio, exp)
    }

    // MARK: - Pressure altitude

    /// Pressure altitude from indicated altitude and current altimeter setting (inHg).
    /// Formula: PA = indicated alt + (29.92 − altimeter) × 1000 ft.
    public static func pressureAltitudeFt(indicatedAltitudeFt: Double, altimeterInHg: Double) -> Double {
        indicatedAltitudeFt + (isaSeaLevelPressureInHg - altimeterInHg) * 1000.0
    }

    /// Pressure altitude with altimeter in hPa.
    public static func pressureAltitudeFt(indicatedAltitudeFt: Double, altimeterHPa: Double) -> Double {
        pressureAltitudeFt(indicatedAltitudeFt: indicatedAltitudeFt,
                           altimeterInHg: hPaToInHg(altimeterHPa))
    }

    // MARK: - Density altitude

    /// Density altitude (FAA approximation): DA = PA + 120 × (OAT − ISA).
    public static func densityAltitudeFt(pressureAltitudeFt: Double, oatC: Double) -> Double {
        let isaC = isaTempC(altitudeFt: pressureAltitudeFt)
        return pressureAltitudeFt + 120.0 * (oatC - isaC)
    }

    /// Density altitude from indicated altitude, altimeter, and OAT.
    public static func densityAltitudeFt(indicatedAltitudeFt: Double,
                                         altimeterInHg: Double,
                                         oatC: Double) -> Double {
        let pa = pressureAltitudeFt(indicatedAltitudeFt: indicatedAltitudeFt, altimeterInHg: altimeterInHg)
        return densityAltitudeFt(pressureAltitudeFt: pa, oatC: oatC)
    }

    // MARK: - True altitude
    //
    // True altitude is the actual MSL altitude. On a non-standard day, the
    // pressure-derived altimeter reading is off by roughly 4 ft per °C of
    // deviation from ISA per 1000 ft of pressure altitude — written here
    // using the ratio form so it stays accurate at any altitude.
    //
    //   TA = IA × (T_actual / T_isa)        (both in Kelvin, ratio form)
    //
    // Rule-of-thumb correction (what pilots compute mentally):
    //   ΔTA = 4 × (OAT − ISA) × (IA / 1000)

    /// True altitude from indicated altitude, altimeter, and OAT.
    public static func trueAltitudeFt(indicatedAltitudeFt: Double,
                                      altimeterInHg: Double,
                                      oatC: Double) -> Double {
        let pa = pressureAltitudeFt(indicatedAltitudeFt: indicatedAltitudeFt,
                                    altimeterInHg: altimeterInHg)
        let isaC = isaTempC(altitudeFt: pa)
        // Ratio form (Kelvin)
        let tActualK = oatC + 273.15
        let tIsaK = isaC + 273.15
        let ratio = tActualK / tIsaK
        return indicatedAltitudeFt * ratio
    }

    /// Quick mental-math correction in feet (FAA rule of thumb).
    public static func trueAltitudeCorrectionFt(indicatedAltitudeFt: Double,
                                                altimeterInHg: Double,
                                                oatC: Double) -> Double {
        let pa = pressureAltitudeFt(indicatedAltitudeFt: indicatedAltitudeFt,
                                    altimeterInHg: altimeterInHg)
        let isaC = isaTempC(altitudeFt: pa)
        return 4.0 * (oatC - isaC) * (indicatedAltitudeFt / 1000.0)
    }
}
