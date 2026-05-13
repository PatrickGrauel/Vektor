import Foundation

/// Weight & balance calculation for a single flight configuration. Each station
/// contributes a moment = weight × arm. Total CG = sum(moments) / sum(weights).
/// An optional envelope (gross-weight polygon in (cg, weight) space) lets us
/// declare in/out-of-envelope.
public struct WeightBalance: Equatable, Sendable {

    public struct Station: Equatable, Sendable {
        public let name: String
        public let weight: Double     // lbs or kg (consistent throughout)
        public let armIn: Double      // inches or cm aft of datum

        public init(name: String, weight: Double, armIn: Double) {
            self.name = name
            self.weight = weight
            self.armIn = armIn
        }

        public var moment: Double { weight * armIn }
    }

    public struct Envelope: Equatable, Sendable {
        /// Polygon vertices, ordered. Each is (cgIn, weight).
        public let vertices: [(Double, Double)]

        public init(vertices: [(Double, Double)]) {
            self.vertices = vertices
        }

        public static func == (lhs: Envelope, rhs: Envelope) -> Bool {
            lhs.vertices.count == rhs.vertices.count
                && zip(lhs.vertices, rhs.vertices).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        }

        /// Even-odd point-in-polygon test.
        public func contains(cg: Double, weight: Double) -> Bool {
            guard vertices.count >= 3 else { return false }
            var inside = false
            var j = vertices.count - 1
            for i in 0..<vertices.count {
                let (xi, yi) = vertices[i]
                let (xj, yj) = vertices[j]
                if ((yi > weight) != (yj > weight)) &&
                    (cg < (xj - xi) * (weight - yi) / (yj - yi) + xi) {
                    inside.toggle()
                }
                j = i
            }
            return inside
        }
    }

    public struct Result: Equatable, Sendable {
        public let totalWeight: Double
        public let totalMoment: Double
        public let cg: Double
        public let inEnvelope: Bool?
    }

    public let stations: [Station]
    public let envelope: Envelope?

    public init(stations: [Station], envelope: Envelope? = nil) {
        self.stations = stations
        self.envelope = envelope
    }

    public func compute() -> Result {
        let totalWeight = stations.reduce(0.0) { $0 + $1.weight }
        let totalMoment = stations.reduce(0.0) { $0 + $1.moment }
        let cg = totalWeight == 0 ? 0 : totalMoment / totalWeight
        let inEnv = envelope?.contains(cg: cg, weight: totalWeight)
        return Result(totalWeight: totalWeight, totalMoment: totalMoment, cg: cg, inEnvelope: inEnv)
    }
}
