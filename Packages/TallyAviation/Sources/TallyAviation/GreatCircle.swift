import Foundation

/// Great-circle distance and bearing on a spherical-earth model.
/// Good to about 0.3 % of true geodesic distance, which is well within
/// the precision pilots care about for flight planning purposes.
public enum GreatCircle {

    /// Earth radius used throughout, in kilometres (WGS-84 mean sphere).
    public static let earthRadiusKM: Double = 6371.0088

    /// Distance in kilometres between two lat/lon points (degrees).
    public static func distanceKM(lat1: Double, lon1: Double,
                                  lat2: Double, lon2: Double) -> Double {
        let φ1 = lat1 * .pi / 180
        let φ2 = lat2 * .pi / 180
        let Δφ = (lat2 - lat1) * .pi / 180
        let Δλ = (lon2 - lon1) * .pi / 180
        let a = sin(Δφ / 2) * sin(Δφ / 2)
              + cos(φ1) * cos(φ2) * sin(Δλ / 2) * sin(Δλ / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))
        return earthRadiusKM * c
    }

    public static func distanceNM(lat1: Double, lon1: Double,
                                  lat2: Double, lon2: Double) -> Double {
        distanceKM(lat1: lat1, lon1: lon1, lat2: lat2, lon2: lon2) * 0.539957
    }

    public static func distanceMiles(lat1: Double, lon1: Double,
                                     lat2: Double, lon2: Double) -> Double {
        distanceKM(lat1: lat1, lon1: lon1, lat2: lat2, lon2: lon2) * 0.621371
    }

    /// Initial true bearing in degrees [0, 360). The track changes
    /// continuously along a great-circle path; this is the heading at
    /// the start of the leg.
    public static func initialBearingTrue(lat1: Double, lon1: Double,
                                          lat2: Double, lon2: Double) -> Double {
        let φ1 = lat1 * .pi / 180
        let φ2 = lat2 * .pi / 180
        let Δλ = (lon2 - lon1) * .pi / 180
        let y = sin(Δλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(Δλ)
        let θ = atan2(y, x)
        return (θ * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }
}
