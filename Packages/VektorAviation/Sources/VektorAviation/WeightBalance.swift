import Foundation

/// Weight & balance calculation for a single flight configuration. Each station
/// contributes a moment = weight × arm. Total CG = sum(moments) / sum(weights).
/// An optional envelope (CG-limits polygon in (cg, weight) space, exactly as
/// drawn in the POH/AFM) lets us declare in/out-of-envelope.
public struct WeightBalance: Equatable, Sendable {

    public struct Station: Equatable, Sendable {
        public let name: String
        public let weight: Double     // lbs or kg (consistent throughout)
        public let armIn: Double      // inches or cm aft of datum
        /// Structural/placard limit for this station (e.g. baggage 120 lb), if any.
        public let maxWeight: Double?
        /// Fuel stations are reduced by the planned burn for the landing
        /// condition and emptied for the zero-fuel condition.
        public let isFuel: Bool

        public init(name: String, weight: Double, armIn: Double,
                    maxWeight: Double? = nil, isFuel: Bool = false) {
            self.name = name
            self.weight = weight
            self.armIn = armIn
            self.maxWeight = maxWeight
            self.isFuel = isFuel
        }

        public var moment: Double { weight * armIn }

        public var isOverLimit: Bool {
            guard let maxWeight else { return false }
            return weight > maxWeight + Envelope.tolerance
        }

        func withWeight(_ w: Double) -> Station {
            Station(name: name, weight: w, armIn: armIn, maxWeight: maxWeight, isFuel: isFuel)
        }
    }

    public struct Envelope: Equatable, Sendable {
        /// Absolute tolerance (in/lb) for "exactly on a limit". POH limits
        /// are inclusive, so a point on the boundary is inside.
        static let tolerance = 1e-6

        /// Polygon vertices, ordered around the boundary. Each is (cg, weight).
        public let vertices: [(Double, Double)]

        public init(vertices: [(Double, Double)]) {
            self.vertices = vertices
        }

        public static func == (lhs: Envelope, rhs: Envelope) -> Bool {
            lhs.vertices.count == rhs.vertices.count
                && zip(lhs.vertices, rhs.vertices).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        }

        /// At least three vertices enclosing a non-zero area.
        public var isValid: Bool {
            vertices.count >= 3 && abs(signedArea) > Envelope.tolerance
        }

        /// True when the envelope is a plain rectangle (one forward and one
        /// aft CG value). Almost no certified aircraft has one — the forward
        /// limit usually moves aft with weight — so the UI warns about it.
        public var isSimpleBox: Bool {
            Set(vertices.map { ($0.0 * 1000).rounded() }).count <= 2
        }

        /// Highest weight on the envelope (normally max takeoff weight).
        public var maxWeight: Double? { vertices.map(\.1).max() }

        private var signedArea: Double {
            guard vertices.count >= 3 else { return 0 }
            var a = 0.0
            for i in 0..<vertices.count {
                let (x1, y1) = vertices[i]
                let (x2, y2) = vertices[(i + 1) % vertices.count]
                a += x1 * y2 - x2 * y1
            }
            return a / 2
        }

        /// Point-in-polygon test, boundary inclusive (a loading exactly on a
        /// published limit is legal). Interior uses the even-odd rule.
        public func contains(cg: Double, weight: Double) -> Bool {
            guard isValid else { return false }
            if isOnBoundary(cg: cg, weight: weight) { return true }
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

        private func isOnBoundary(cg: Double, weight: Double) -> Bool {
            for i in 0..<vertices.count {
                let (x1, y1) = vertices[i]
                let (x2, y2) = vertices[(i + 1) % vertices.count]
                let dx = x2 - x1, dy = y2 - y1
                let lenSq = dx * dx + dy * dy
                let t = lenSq == 0 ? 0 : max(0, min(1, ((cg - x1) * dx + (weight - y1) * dy) / lenSq))
                let px = x1 + t * dx, py = y1 + t * dy
                if abs(cg - px) <= Envelope.tolerance && abs(weight - py) <= Envelope.tolerance {
                    return true
                }
            }
            return false
        }
    }

    public struct Result: Equatable, Sendable {
        public let totalWeight: Double
        public let totalMoment: Double
        public let cg: Double
        public let inEnvelope: Bool?
    }

    public enum ConditionKind: String, Sendable, CaseIterable {
        case takeoff = "Takeoff"
        case landing = "Landing"
        case zeroFuel = "Zero fuel"
    }

    public struct Condition: Equatable, Sendable {
        public let kind: ConditionKind
        public let result: Result
        public let fuelWeight: Double
    }

    /// Every check the loading must pass, across the flight.
    public struct Evaluation: Equatable, Sendable {
        /// Takeoff always; landing and zero-fuel when a fuel station exists.
        public let conditions: [Condition]
        public let overLimitStations: [String]
        public let negativeWeightStations: [String]
        /// Planned burn is more than the fuel on board.
        public let fuelBurnExceedsFuel: Bool
        /// A burn was entered but no station is marked as fuel.
        public let fuelBurnWithoutFuelStation: Bool
        public let envelopeValid: Bool

        /// The single go/no-go verdict. Every condition must be inside the
        /// envelope and no other check may fail.
        public var isWithinLimits: Bool {
            envelopeValid
                && !conditions.isEmpty
                && conditions.allSatisfy { $0.result.totalWeight > 0 && $0.result.inEnvelope == true }
                && overLimitStations.isEmpty
                && negativeWeightStations.isEmpty
                && !fuelBurnExceedsFuel
                && !fuelBurnWithoutFuelStation
        }

        /// Human-readable reasons the loading fails, for display.
        public var problems: [String] {
            var out: [String] = []
            if !envelopeValid { out.append("Envelope needs at least 3 corners enclosing an area.") }
            for c in conditions where c.result.totalWeight > 0 && c.result.inEnvelope != true {
                out.append("\(c.kind.rawValue): outside the CG envelope.")
            }
            for name in overLimitStations { out.append("\(name): over its station limit.") }
            for name in negativeWeightStations { out.append("\(name): negative weight.") }
            if fuelBurnExceedsFuel { out.append("Planned burn is more than the fuel on board.") }
            if fuelBurnWithoutFuelStation { out.append("Fuel burn entered but no station is marked as fuel.") }
            return out
        }
    }

    public let stations: [Station]
    public let envelope: Envelope?

    public init(stations: [Station], envelope: Envelope? = nil) {
        self.stations = stations
        self.envelope = envelope
    }

    public func compute() -> Result {
        Self.compute(stations, envelope: envelope)
    }

    private static func compute(_ stations: [Station], envelope: Envelope?) -> Result {
        let totalWeight = stations.reduce(0.0) { $0 + $1.weight }
        let totalMoment = stations.reduce(0.0) { $0 + $1.moment }
        let cg = totalWeight == 0 ? 0 : totalMoment / totalWeight
        let inEnv = envelope?.contains(cg: cg, weight: totalWeight)
        return Result(totalWeight: totalWeight, totalMoment: totalMoment, cg: cg, inEnvelope: inEnv)
    }

    /// Evaluate takeoff, landing (after `fuelBurn`) and zero-fuel conditions.
    /// With several fuel stations the burn is taken from each in proportion
    /// to its load — exact for a single tank or symmetric wing tanks at the
    /// same arm; for tanks at different arms enter the burn sequence per POH.
    public func evaluate(fuelBurn: Double) -> Evaluation {
        let fuelStations = stations.filter(\.isFuel)
        let fuelOnBoard = fuelStations.reduce(0.0) { $0 + max($1.weight, 0) }
        let burn = max(fuelBurn, 0)

        var conditions = [Condition(kind: .takeoff,
                                    result: compute(),
                                    fuelWeight: fuelOnBoard)]
        if !fuelStations.isEmpty {
            let remainingFraction = fuelOnBoard > 0 ? max(0, (fuelOnBoard - burn) / fuelOnBoard) : 0
            let landing = stations.map { $0.isFuel ? $0.withWeight(max($0.weight, 0) * remainingFraction) : $0 }
            conditions.append(Condition(kind: .landing,
                                        result: Self.compute(landing, envelope: envelope),
                                        fuelWeight: fuelOnBoard * remainingFraction))
            let zeroFuel = stations.map { $0.isFuel ? $0.withWeight(0) : $0 }
            conditions.append(Condition(kind: .zeroFuel,
                                        result: Self.compute(zeroFuel, envelope: envelope),
                                        fuelWeight: 0))
        }

        return Evaluation(
            conditions: conditions,
            overLimitStations: stations.filter(\.isOverLimit).map(\.name),
            negativeWeightStations: stations.filter { $0.weight < 0 }.map(\.name),
            fuelBurnExceedsFuel: !fuelStations.isEmpty && burn > fuelOnBoard + Envelope.tolerance,
            fuelBurnWithoutFuelStation: fuelStations.isEmpty && burn > 0,
            envelopeValid: envelope?.isValid ?? false
        )
    }
}
