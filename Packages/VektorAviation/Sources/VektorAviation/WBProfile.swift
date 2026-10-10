import Foundation

/// An editable, persistable weight & balance setup: the loading stations and
/// the CG envelope polygon, both copied by the pilot from their own POH/AFM.
/// Shared by the macOS and iPad apps so both run the same checks.
public struct WBProfile: Codable, Equatable, Identifiable, Sendable {

    public struct Station: Codable, Equatable, Identifiable, Sendable {
        public var id: UUID
        public var name: String
        public var weight: Double
        public var arm: Double
        /// Placard / structural limit for this station; nil = none.
        public var maxWeight: Double?
        public var isFuel: Bool

        public init(id: UUID = UUID(), name: String, weight: Double, arm: Double,
                    maxWeight: Double? = nil, isFuel: Bool = false) {
            self.id = id
            self.name = name
            self.weight = weight
            self.arm = arm
            self.maxWeight = maxWeight
            self.isFuel = isFuel
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            weight = try c.decodeIfPresent(Double.self, forKey: .weight) ?? 0
            arm = try c.decodeIfPresent(Double.self, forKey: .arm) ?? 0
            maxWeight = try c.decodeIfPresent(Double.self, forKey: .maxWeight)
            // Profiles saved before fuel stations existed: infer from the name
            // ("Fuel (40 gal)"). The UI shows the flag so the pilot can fix it.
            isFuel = try c.decodeIfPresent(Bool.self, forKey: .isFuel)
                ?? name.localizedCaseInsensitiveContains("fuel")
        }
    }

    /// One corner of the CG envelope, as read off the POH chart.
    public struct Point: Codable, Equatable, Identifiable, Sendable {
        public var id: UUID
        public var cg: Double
        public var weight: Double

        public init(id: UUID = UUID(), cg: Double, weight: Double) {
            self.id = id
            self.cg = cg
            self.weight = weight
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            cg = try c.decode(Double.self, forKey: .cg)
            weight = try c.decode(Double.self, forKey: .weight)
        }
    }

    public var id: UUID
    public var name: String
    public var stations: [Station]
    /// Envelope vertices in order around the boundary.
    public var envelope: [Point]
    /// Planned fuel burn (same weight unit) for the landing condition.
    public var fuelBurn: Double

    public init(id: UUID = UUID(), name: String, stations: [Station],
                envelope: [Point], fuelBurn: Double = 0) {
        self.id = id
        self.name = name
        self.stations = stations
        self.envelope = envelope
        self.fuelBurn = fuelBurn
    }

    private enum CodingKeys: String, CodingKey { case id, name, stations, envelope, fuelBurn }

    /// Pre-polygon saves stored `{minCG, maxCG, maxWeight}`.
    private struct LegacyBox: Decodable { let minCG: Double; let maxCG: Double; let maxWeight: Double }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Aircraft"
        stations = try c.decodeIfPresent([Station].self, forKey: .stations) ?? []
        fuelBurn = try c.decodeIfPresent(Double.self, forKey: .fuelBurn) ?? 0
        if let points = try? c.decode([Point].self, forKey: .envelope) {
            envelope = points
        } else if let box = try? c.decode(LegacyBox.self, forKey: .envelope) {
            envelope = [
                Point(cg: box.minCG, weight: 0),
                Point(cg: box.maxCG, weight: 0),
                Point(cg: box.maxCG, weight: box.maxWeight),
                Point(cg: box.minCG, weight: box.maxWeight),
            ]
        } else {
            envelope = []
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(stations, forKey: .stations)
        try c.encode(envelope, forKey: .envelope)
        try c.encode(fuelBurn, forKey: .fuelBurn)
    }

    public var weightBalance: WeightBalance {
        WeightBalance(
            stations: stations.map {
                .init(name: $0.name, weight: $0.weight, armIn: $0.arm,
                      maxWeight: $0.maxWeight, isFuel: $0.isFuel)
            },
            envelope: .init(vertices: envelope.map { ($0.cg, $0.weight) })
        )
    }

    public func evaluate() -> WeightBalance.Evaluation {
        weightBalance.evaluate(fuelBurn: fuelBurn)
    }

    // MARK: - Starting points
    //
    // Deliberately NOT named after real aircraft types: generic numbers under
    // a type name get trusted as that type's data. Every real setup must come
    // from the specific airframe's POH/AFM and current weighing report.

    /// A fictional four-seat single, shaped like a typical envelope (forward
    /// limit sloping aft above a break-point weight). Demonstration only.
    public static let example = WBProfile(
        name: "Example (fictional — not for flight)",
        stations: [
            Station(name: "Basic empty weight", weight: 1450, arm: 38.5),
            Station(name: "Front seats", weight: 340, arm: 37.0),
            Station(name: "Rear seats", weight: 0, arm: 72.0),
            Station(name: "Fuel", weight: 240, arm: 47.0, maxWeight: 300, isFuel: true),
            Station(name: "Baggage", weight: 30, arm: 94.0, maxWeight: 120),
        ],
        envelope: [
            Point(cg: 34.0, weight: 1400),
            Point(cg: 34.0, weight: 1900),
            Point(cg: 40.0, weight: 2500),
            Point(cg: 46.0, weight: 2500),
            Point(cg: 46.0, weight: 1400),
        ],
        fuelBurn: 60
    )

    /// Empty template for entering a real aircraft from its POH.
    public static let blank = WBProfile(
        name: "New aircraft",
        stations: [
            Station(name: "Basic empty weight", weight: 0, arm: 0),
            Station(name: "Fuel", weight: 0, arm: 0, isFuel: true),
        ],
        envelope: []
    )
}
