import Foundation

/// Fuel + simple flight-planning math.
public enum Fuel {

    /// Endurance in hours from fuel quantity / burn rate.
    /// - Parameters:
    ///   - fuelQty: fuel on board (e.g. gallons).
    ///   - burnRate: consumption per hour (same units).
    public static func enduranceHours(fuelQty: Double, burnRate: Double) -> Double {
        guard burnRate > 0 else { return .infinity }
        return fuelQty / burnRate
    }

    /// Range from endurance & ground speed.
    public static func range(fuelQty: Double, burnRate: Double, groundSpeed: Double) -> Double {
        enduranceHours(fuelQty: fuelQty, burnRate: burnRate) * groundSpeed
    }

    /// Estimated time en route in hours.
    public static func eteHours(distance: Double, groundSpeed: Double) -> Double {
        guard groundSpeed > 0 else { return .infinity }
        return distance / groundSpeed
    }

    /// Top-of-descent distance to lose `altitudeToLose` feet at a target descent rate
    /// (ft/min) and ground speed (units consistent with distance).
    public static func topOfDescentDistance(altitudeToLoseFt: Double,
                                            descentRateFpm: Double,
                                            groundSpeed: Double) -> Double {
        guard descentRateFpm > 0 else { return .infinity }
        let minutes = altitudeToLoseFt / descentRateFpm
        let hours = minutes / 60.0
        return hours * groundSpeed
    }
}
