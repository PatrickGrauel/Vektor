import Foundation

/// Wind-based runway-in-use recommendation: pick the runway end whose
/// alignment gives the most headwind (and least crosswind as a
/// tiebreaker), and report head/cross components — including gust
/// components when the METAR carries a gust.
///
/// The output is a *suggestion*, not an assertion. Tally has no way to
/// know which runway ATIS / Tower has actually nominated; it just
/// computes the most-favourable end from the wind reported in the
/// METAR. Display copy in NumiEngine reflects this with the
/// "expect RWY xx …" wording.
public enum RunwayWindAdvisor {

    public struct Advice: Sendable, Equatable {
        /// Magnetic designator of the runway end (e.g. "26L", "08", "36R").
        public let designator: String
        /// Headwind component, kt. Negative means tailwind — in that
        /// case `isTailwind` is true so the caller can colour
        /// accordingly. The chosen end is the LEAST UNFAVOURABLE one
        /// when no headwind option exists.
        public let headwindKt: Int
        public let crosswindKt: Int
        /// Side the crosswind comes from. Lets the renderer show
        /// "Xc 5L" / "Xc 5R" if you want to.
        public let crosswindFromRight: Bool
        public let isTailwind: Bool
        /// Same components computed against the gust speed. `nil` if
        /// the METAR didn't include a gust value.
        public let headwindGustKt: Int?
        public let crosswindGustKt: Int?
    }

    /// Compute the best runway recommendation for a METAR's wind
    /// against an airport's runway list.
    ///
    /// Returns `nil` when:
    ///   - the METAR has no wind group, or
    ///   - the wind is calm (00000KT — speed ≤ 0), or
    ///   - the wind is `VRB` with no usable direction AND the speed
    ///     is < 6 kt (variability at low speed has no meaningful
    ///     runway preference), or
    ///   - the runway list is empty.
    public static func advise(metar: DecodedMetar, runways: [RunwayInfo]) -> Advice? {
        guard let wind = metar.wind else { return nil }
        // Calm: no preference.
        if wind.speedKt <= 0 { return nil }
        // Variable < 6 kt: no preference (light & swirly).
        if wind.isVariable && wind.speedKt < 6 { return nil }
        // VRB without a from-direction we can use → bail.
        guard let windFrom = wind.fromDeg else { return nil }
        // Filter out closed runways AND ends with no usable heading.
        let useable = runways.filter { !$0.closed }
        guard !useable.isEmpty else { return nil }

        // Score every end of every runway. End = (designator, trueHeading).
        struct Scored {
            let designator: String
            let head: Double
            let cross: Double
            let crossFromRight: Bool
            let headGust: Double?
            let crossGust: Double?
        }
        var scored: [Scored] = []
        scored.reserveCapacity(useable.count * 2)
        for r in useable {
            if !r.leHeadingTrue.isNaN {
                let c = Runway.components(runwayHeadingDeg: r.leHeadingTrue,
                                          windFromDeg: Double(windFrom),
                                          windSpeed: Double(wind.speedKt))
                let gust: (Double, Double)? = wind.gustKt.map { g in
                    let cg = Runway.components(runwayHeadingDeg: r.leHeadingTrue,
                                               windFromDeg: Double(windFrom),
                                               windSpeed: Double(g))
                    return (cg.headwind, cg.crosswind)
                }
                scored.append(Scored(
                    designator: r.leIdent,
                    head: c.headwind, cross: c.crosswind,
                    crossFromRight: c.crosswindFromRight,
                    headGust: gust?.0, crossGust: gust?.1
                ))
            }
            if !r.heHeadingTrue.isNaN {
                let c = Runway.components(runwayHeadingDeg: r.heHeadingTrue,
                                          windFromDeg: Double(windFrom),
                                          windSpeed: Double(wind.speedKt))
                let gust: (Double, Double)? = wind.gustKt.map { g in
                    let cg = Runway.components(runwayHeadingDeg: r.heHeadingTrue,
                                               windFromDeg: Double(windFrom),
                                               windSpeed: Double(g))
                    return (cg.headwind, cg.crosswind)
                }
                scored.append(Scored(
                    designator: r.heIdent,
                    head: c.headwind, cross: c.crosswind,
                    crossFromRight: c.crosswindFromRight,
                    headGust: gust?.0, crossGust: gust?.1
                ))
            }
        }
        guard !scored.isEmpty else { return nil }

        // Rank: maximise headwind first, minimise crosswind on ties.
        // Lexicographic ascending designator as the final tiebreaker
        // so the choice is deterministic.
        let best = scored.sorted { lhs, rhs in
            if lhs.head != rhs.head { return lhs.head > rhs.head }
            if lhs.cross != rhs.cross { return lhs.cross < rhs.cross }
            return lhs.designator < rhs.designator
        }.first!

        return Advice(
            designator: best.designator,
            headwindKt: Int(best.head.rounded()),
            crosswindKt: Int(best.cross.rounded()),
            crosswindFromRight: best.crossFromRight,
            isTailwind: best.head < 0,
            headwindGustKt: best.headGust.map { Int($0.rounded()) },
            crosswindGustKt: best.crossGust.map { Int($0.rounded()) }
        )
    }
}
