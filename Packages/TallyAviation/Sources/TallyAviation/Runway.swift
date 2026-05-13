import Foundation

/// Runway wind component math.
public enum Runway {

    public struct Components: Equatable, Sendable {
        /// Headwind component (negative = tailwind).
        public let headwind: Double
        /// Crosswind component absolute value.
        public let crosswind: Double
        /// Sign of crosswind: -1 from the left, +1 from the right.
        public let crosswindFromRight: Bool
    }

    /// Compute head/cross components for a runway heading and wind.
    /// - Parameters:
    ///   - runwayHeadingDeg: runway magnetic heading (e.g. 270 for runway 27).
    ///   - windFromDeg: direction wind is coming from (degrees, same reference as runway).
    ///   - windSpeed: wind speed, in any unit.
    public static func components(runwayHeadingDeg: Double,
                                  windFromDeg: Double,
                                  windSpeed: Double) -> Components {
        let angleDeg = ((windFromDeg - runwayHeadingDeg)
                        .truncatingRemainder(dividingBy: 360) + 540)
                        .truncatingRemainder(dividingBy: 360) - 180
        let angleRad = angleDeg * .pi / 180.0
        let head = windSpeed * cos(angleRad)
        let cross = windSpeed * sin(angleRad)
        return Components(
            headwind: head,
            crosswind: abs(cross),
            crosswindFromRight: cross >= 0
        )
    }

    /// Parse runway identifier ("27", "27L", "09R") into a heading in degrees magnetic.
    public static func headingFromRunwayId(_ id: String) -> Double? {
        let trimmed = id.trimmingCharacters(in: .whitespaces).uppercased()
        let digits = trimmed.prefix(while: { $0.isNumber })
        guard let n = Int(digits), n >= 1, n <= 36 else { return nil }
        return Double(n) * 10.0
    }
}
