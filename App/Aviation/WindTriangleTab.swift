import SwiftUI
import TallyAviation

struct WindTriangleTab: View {
    @AppStorage("tally.e6b.wind.course")    private var course: Double = 52      // TC
    @AppStorage("tally.e6b.wind.tas")       private var tas: Double = 120
    @AppStorage("tally.e6b.wind.windFrom")  private var windFrom: Double = 280
    @AppStorage("tally.e6b.wind.windSpeed") private var windSpeed: Double = 15
    @AppStorage("tally.e6b.wind.variation") private var variation: Double = 7    // °W positive
    @AppStorage("tally.e6b.wind.deviation") private var deviation: Double = 5    // compass deviation

    @AppStorage("tally.e6b.wind.show.true")    private var showTrue: Bool = true
    @AppStorage("tally.e6b.wind.show.mag")     private var showMag: Bool = true
    @AppStorage("tally.e6b.wind.show.compass") private var showCompass: Bool = false
    @AppStorage("tally.e6b.wind.show.course")  private var showCourse: Bool = true
    @AppStorage("tally.e6b.wind.show.heading") private var showHeading: Bool = true
    @AppStorage("tally.e6b.wind.show.track")   private var showTrack: Bool = false
    @AppStorage("tally.e6b.wind.show.wind")    private var showWind: Bool = true
    @AppStorage("tally.e6b.wind.show.aircraft") private var showAircraft: Bool = true

    var body: some View {
        let s = E6B.windTriangle(courseDeg: course, tas: tas, windFromDeg: windFrom, windSpeed: windSpeed)
        let th = s.headingDeg

        return Form {
            // 1. Inputs first — what the pilot is typing into the calculator.
            Section("Inputs") {
                NumericField(title: "True Course (TC)",   value: $course,    range: 0...360, suffix: "°")
                NumericField(title: "True Airspeed (TAS)", value: $tas,      range: 0...500, suffix: "kt")
                NumericField(title: "Wind from",          value: $windFrom,  range: 0...360, suffix: "°")
                NumericField(title: "Wind speed",         value: $windSpeed, range: 0...80,  suffix: "kt")
                NumericField(title: "Mag variation",      value: $variation, range: -30...30,
                             suffix: variation >= 0 ? "°W" : "°E",
                             format: .number.precision(.fractionLength(0...1)))
                NumericField(title: "Compass deviation",  value: $deviation, range: -10...10,
                             suffix: deviation >= 0 ? "°E" : "°W",
                             format: .number.precision(.fractionLength(0...1)))
            }

            // 2. Result — what the math gives you.
            Section("Result") {
                LabeledContent("Wind Correction (WCA)", value: String(format: "%+.1f°", s.wcaDeg))
                LabeledContent("True Course (TC)",      value: String(format: "%03.0f°", course))
                LabeledContent("True Heading (TH)",     value: String(format: "%03.0f°", th))
                LabeledContent("Magnetic Course (MC)",  value: String(format: "%03.0f°", normalize(course + variation)))
                LabeledContent("Magnetic Heading (MH)", value: String(format: "%03.0f°", normalize(th + variation)))
                LabeledContent("Compass Heading (CH)",  value: String(format: "%03.0f°", normalize(th + variation + deviation)))
                LabeledContent("Ground Speed (GS)",     value: String(format: "%.0f kt", s.groundSpeed))
                LabeledContent("Headwind",              value: String(format: "%+.0f kt", s.headwind))
                LabeledContent("Crosswind",             value: String(format: "%.0f kt %@", abs(s.crosswind), s.crosswind == 0 ? "" : (s.crosswind > 0 ? "(R)" : "(L)")))
            }

            // 3. Graph — the visualisation, plus its own selection bar.
            Section("Show on diagram") {
                visibilityToggles
            }

            Section("Diagram") {
                NavigationFan(
                    course: course, tas: tas, windFromDeg: windFrom, windSpeed: windSpeed,
                    variation: variation, deviation: deviation,
                    solution: s,
                    showTrue: showTrue, showMag: showMag, showCompass: showCompass,
                    showCourse: showCourse, showHeading: showHeading, showTrack: showTrack,
                    showWind: showWind, showAircraft: showAircraft
                )
                .frame(height: 380)
                .background(TallyTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private var visibilityToggles: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
            GridRow {
                Text("Norths").font(.caption).foregroundStyle(.secondary)
                Toggle("True",     isOn: $showTrue)
                Toggle("Magnetic", isOn: $showMag)
                Toggle("Compass",  isOn: $showCompass)
            }
            GridRow {
                Text("Lines").font(.caption).foregroundStyle(.secondary)
                Toggle("Course",  isOn: $showCourse)
                Toggle("Heading", isOn: $showHeading)
                Toggle("Track",   isOn: $showTrack)
            }
            GridRow {
                Text("Overlay").font(.caption).foregroundStyle(.secondary)
                Toggle("Wind",     isOn: $showWind)
                Toggle("Aircraft", isOn: $showAircraft)
                Color.clear
            }
        }
        .toggleStyle(.checkbox)
    }

    private func normalize(_ deg: Double) -> Double {
        let r = deg.truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }
}

// MARK: - Navigation fan diagram
//
// Ported from the Claude Design "Tally Wind-Face" deliverable. Origin near the
// bottom-left; three north rays (True / Mag / Compass) fan upward, three
// trajectory rays (Course / Heading / Track) fan to the right. Concentric
// arcs link each north to each trajectory. Correction indicators near the
// origin name the angular gaps a pilot actually computes (VAR, DEV, WCA, DA).
// Each tier is independently toggleable from the parent view.

private struct NavigationFan: View {
    let course: Double           // TC
    let tas: Double
    let windFromDeg: Double
    let windSpeed: Double
    let variation: Double
    let deviation: Double
    let solution: E6B.WindSolution

    let showTrue: Bool
    let showMag: Bool
    let showCompass: Bool
    let showCourse: Bool
    let showHeading: Bool
    let showTrack: Bool
    let showWind: Bool
    let showAircraft: Bool

    // Palette from the Claude Design delivery
    private let cTrue    = Color(red: 0x5A/255, green: 0xC8/255, blue: 0xFA/255)
    private let cMag     = Color(red: 0xFF/255, green: 0x6B/255, blue: 0x6B/255)
    private let cCompass = Color(red: 0x3D/255, green: 0xD6/255, blue: 0x8C/255)
    private let cAxis    = Color.white
    private let cMuted   = Color.white.opacity(0.7)

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                draw(in: &context, size: size)
            }
            .padding(20)
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        // Mirror the HTML reference: 720×540 viewBox with origin near bottom-left.
        let viewW: Double = 720, viewH: Double = 540
        let scale = min(size.width / viewW, size.height / viewH)
        let ox = 110.0 * scale
        let oy = 475.0 * scale
        let nLen = 420.0 * scale
        let tLen = 470.0 * scale

        // Resolved angles (clockwise from up, in degrees)
        let tNorth: Double = 0
        let mNorth = variation                       // +°W shifts magnetic CW
        let cNorth = variation + deviation
        let tc = course
        let th = solution.headingDeg
        let track = course                            // ground track ~= TC (no DA model yet)

        let norths: [(key: String, angle: Double, color: Color, shown: Bool, label: String)] = [
            ("T", tNorth, cTrue,    showTrue,    "True"),
            ("M", mNorth, cMag,     showMag,     "Magnetic"),
            ("C", cNorth, cCompass, showCompass, "Compass"),
        ]
        let trajs: [(key: String, angle: Double, shown: Bool, label: String)] = [
            ("C", tc,    showCourse,  "Course"),
            ("H", th,    showHeading, "Heading"),
            ("T", track, showTrack,   "Track"),
        ]

        // ---- 1) Wind barb overlay (drawn first, behind everything) ----
        if showWind {
            drawWindBarb(in: &context, scale: scale,
                          windFromDeg: windFromDeg, windSpeed: windSpeed)
        }

        // ---- 2) North rays + labels ----
        for n in norths where n.shown {
            let tip = polar(ox: ox, oy: oy, r: nLen, deg: n.angle)
            stroke(in: &context,
                   from: CGPoint(x: ox, y: oy), to: tip,
                   color: n.color, width: 1.8)
            arrowhead(in: &context, at: tip,
                      direction: n.angle, color: n.color, size: 7 * scale)
            let labelOffset = labelOffsetForNorth(key: n.key)
            let labelPos = CGPoint(x: tip.x + labelOffset.x * scale,
                                   y: tip.y - 18 * scale)
            let anchor: UnitPoint = (n.key == "T") ? .trailing
                                  : (n.key == "C") ? .leading : .center
            drawText(in: &context, at: labelPos, anchor: anchor,
                     n.label, font: .system(size: 13 * scale, weight: .semibold),
                     color: n.color)
        }

        // ---- 3) Trajectory rays + labels ----
        for t in trajs where t.shown {
            let tip = polar(ox: ox, oy: oy, r: tLen, deg: t.angle)
            stroke(in: &context, from: CGPoint(x: ox, y: oy), to: tip,
                   color: cAxis, width: 1.8)
            arrowhead(in: &context, at: tip, direction: t.angle, color: cAxis, size: 7 * scale)
            let labelPos = polar(ox: ox, oy: oy, r: tLen + 38 * scale, deg: t.angle)
            drawText(in: &context, at: labelPos, anchor: .leading,
                     t.label, font: .system(size: 13 * scale, weight: .semibold), color: cAxis)
        }

        // ---- 4) Arcs (each visible north → each visible trajectory) ----
        let tiers: [(traj: String, baseR: Double)] = [
            ("C", 370), ("H", 290), ("T", 210)
        ]
        let northOffsets: [String: Double] = ["T": 0, "M": -25, "C": -50]
        for tier in tiers {
            guard let traj = trajs.first(where: { $0.key == tier.traj && $0.shown }) else { continue }
            for n in norths where n.shown {
                let r = (tier.baseR + (northOffsets[n.key] ?? 0)) * scale
                guard r > 0 else { continue }
                drawArc(in: &context,
                        center: CGPoint(x: ox, y: oy),
                        radius: r,
                        startDeg: n.angle, endDeg: traj.angle,
                        color: n.color, label: "\(n.key)\(traj.key)",
                        scale: scale)
                // Small dot pinning arc start to its north line.
                let dot = polar(ox: ox, oy: oy, r: r, deg: n.angle)
                let rect = CGRect(x: dot.x - 2.4 * scale, y: dot.y - 2.4 * scale,
                                  width: 4.8 * scale, height: 4.8 * scale)
                context.fill(Path(ellipseIn: rect), with: .color(n.color))
            }
        }

        // ---- 5) Correction indicators (VAR, DEV, WCA) ----
        let corrections: [(label: String, r: Double, a1: Double, a2: Double, labelR: Double)] = [
            ("VAR", 85,  0,         variation,      108),
            ("DEV", 120, variation, variation + deviation, 142),
            ("WCA", 85,  course,    th,             108),
        ]
        for c in corrections where abs(c.a1 - c.a2) > 0.5 {
            let r = c.r * scale
            drawCorrectionArc(in: &context,
                              center: CGPoint(x: ox, y: oy),
                              radius: r,
                              startDeg: c.a1, endDeg: c.a2)
            let labelPos = polar(ox: ox, oy: oy,
                                 r: c.labelR * scale,
                                 deg: (c.a1 + c.a2) / 2)
            let pillW = Double(c.label.count) * 6.4 + 8
            let pill = CGRect(x: labelPos.x - pillW * scale / 2,
                              y: labelPos.y - 7 * scale,
                              width: pillW * scale, height: 14 * scale)
            context.fill(Path(roundedRect: pill, cornerRadius: 3 * scale),
                         with: .color(TallyTheme.surface))
            drawText(in: &context, at: labelPos, anchor: .center,
                     c.label,
                     font: .system(size: 9.5 * scale, weight: .semibold, design: .monospaced),
                     color: cMuted)
        }

        // ---- 6) Origin dot ----
        let originDot = CGRect(x: ox - 4.5 * scale, y: oy - 4.5 * scale,
                               width: 9 * scale, height: 9 * scale)
        context.fill(Path(ellipseIn: originDot), with: .color(cAxis))

        // ---- 7) Aircraft silhouette along Track ray, rotated to Heading ----
        if showAircraft {
            let pos = polar(ox: ox, oy: oy, r: 380 * scale, deg: track)
            var local = context
            local.translateBy(x: pos.x, y: pos.y)
            local.rotate(by: .degrees(th))
            local.fill(aircraftPath(span: 34 * scale),
                       with: .color(Color.white.opacity(0.88)))
        }
    }

    // MARK: - Drawing helpers

    private func stroke(in context: inout GraphicsContext,
                        from: CGPoint, to: CGPoint,
                        color: Color, width: CGFloat) {
        var p = Path()
        p.move(to: from); p.addLine(to: to)
        context.stroke(p, with: .color(color), lineWidth: width)
    }

    private func arrowhead(in context: inout GraphicsContext,
                           at tip: CGPoint, direction: Double,
                           color: Color, size: CGFloat) {
        let rad = direction * .pi / 180
        let ux = sin(rad), uy = -cos(rad)         // forward (clockwise-from-up)
        let px = -uy,        py = ux              // perpendicular
        let back = CGPoint(x: tip.x - ux * size, y: tip.y - uy * size)
        let left = CGPoint(x: back.x + px * size * 0.55, y: back.y + py * size * 0.55)
        let right = CGPoint(x: back.x - px * size * 0.55, y: back.y - py * size * 0.55)
        var p = Path()
        p.move(to: tip); p.addLine(to: left); p.addLine(to: right); p.closeSubpath()
        context.fill(p, with: .color(color))
    }

    private func drawArc(in context: inout GraphicsContext,
                         center: CGPoint, radius: CGFloat,
                         startDeg: Double, endDeg: Double,
                         color: Color, label: String, scale: Double) {
        // SwiftUI Path arc: 0° = right, increasing CCW. Our convention is
        // 0° = up (north), increasing CW. Convert by subtracting 90° from
        // (deg) and negating Y axis: SwiftUI's clockwise: false maps right.
        var path = Path()
        path.addArc(center: center, radius: radius,
                    startAngle: .degrees(startDeg - 90),
                    endAngle: .degrees(endDeg - 90),
                    clockwise: false)
        context.stroke(path, with: .color(color), lineWidth: 1.3)

        let midDeg = (startDeg + endDeg) / 2
        let labelPos = polar(ox: center.x, oy: center.y,
                             r: radius + 14 * scale, deg: midDeg)
        drawText(in: &context, at: labelPos, anchor: .center,
                 label,
                 font: .system(size: 11 * scale, weight: .semibold, design: .monospaced),
                 color: color)
    }

    private func drawCorrectionArc(in context: inout GraphicsContext,
                                   center: CGPoint, radius: CGFloat,
                                   startDeg: Double, endDeg: Double) {
        var path = Path()
        let lo = min(startDeg, endDeg)
        let hi = max(startDeg, endDeg)
        path.addArc(center: center, radius: radius,
                    startAngle: .degrees(lo - 90),
                    endAngle: .degrees(hi - 90),
                    clockwise: false)
        context.stroke(path, with: .color(cMuted), lineWidth: 0.9)
    }

    private func drawText(in context: inout GraphicsContext,
                          at pos: CGPoint, anchor: UnitPoint,
                          _ text: String, font: Font, color: Color) {
        let t = Text(text).font(font).foregroundStyle(color)
        context.draw(t, at: pos, anchor: anchor)
    }

    private func drawWindBarb(in context: inout GraphicsContext, scale: Double,
                              windFromDeg: Double, windSpeed: Double) {
        let staffOrigin = CGPoint(x: 510 * scale + 20, y: 92 * scale + 20)
        let dir = windFromDeg * .pi / 180
        let length: Double = 70 * scale
        let dx = sin(dir + .pi) * length    // direction wind is going (toward origin's diagonal)
        let dy = -cos(dir + .pi) * length
        let tip = CGPoint(x: staffOrigin.x + dx, y: staffOrigin.y + dy)
        stroke(in: &context, from: staffOrigin, to: tip, color: cTrue, width: 1.4)

        // Feathers: one full feather per 10 kt, half feather per 5 kt.
        let perp = CGPoint(x: cos(dir + .pi) * 12 * scale,
                           y: sin(dir + .pi) * 12 * scale)
        var remaining = Int(windSpeed)
        var t: Double = 0.18
        while remaining >= 10 && t < 0.9 {
            let basePt = CGPoint(x: staffOrigin.x + dx * t, y: staffOrigin.y + dy * t)
            let endPt = CGPoint(x: basePt.x + perp.x, y: basePt.y + perp.y)
            stroke(in: &context, from: basePt, to: endPt, color: cTrue, width: 1.4)
            remaining -= 10
            t += 0.12
        }
        if remaining >= 5 {
            let basePt = CGPoint(x: staffOrigin.x + dx * t, y: staffOrigin.y + dy * t)
            let endPt = CGPoint(x: basePt.x + perp.x * 0.55, y: basePt.y + perp.y * 0.55)
            stroke(in: &context, from: basePt, to: endPt, color: cTrue, width: 1.4)
        }

        let labelPos = CGPoint(x: tip.x + 10 * scale, y: tip.y + 4 * scale)
        drawText(in: &context, at: labelPos, anchor: .leading,
                 String(format: "WIND · %03.0f°/%.0f", windFromDeg, windSpeed),
                 font: .system(size: 10 * scale, weight: .semibold, design: .monospaced),
                 color: cTrue)
    }

    private func aircraftPath(span: Double) -> Path {
        let s = span / 32
        let pts: [CGPoint] = [
            CGPoint(x:  0,      y: -14*s),
            CGPoint(x:  1.5*s,  y:  -8*s),
            CGPoint(x:  1.5*s,  y:   4*s),
            CGPoint(x: 14*s,    y:   5*s),
            CGPoint(x: 14*s,    y:   7*s),
            CGPoint(x:  1.5*s,  y:   8*s),
            CGPoint(x:  1.5*s,  y:  12*s),
            CGPoint(x:  4*s,    y:  13*s),
            CGPoint(x:  4*s,    y:  14*s),
            CGPoint(x: -4*s,    y:  14*s),
            CGPoint(x: -4*s,    y:  13*s),
            CGPoint(x: -1.5*s,  y:  12*s),
            CGPoint(x: -1.5*s,  y:   8*s),
            CGPoint(x: -14*s,   y:   7*s),
            CGPoint(x: -14*s,   y:   5*s),
            CGPoint(x: -1.5*s,  y:   4*s),
            CGPoint(x: -1.5*s,  y:  -8*s),
        ]
        var p = Path()
        p.move(to: pts[0])
        for i in 1..<pts.count { p.addLine(to: pts[i]) }
        p.closeSubpath()
        return p
    }

    private func labelOffsetForNorth(key: String) -> CGPoint {
        switch key {
        case "T": return CGPoint(x: -6, y: 0)
        case "C": return CGPoint(x:  6, y: 0)
        default:  return .zero
        }
    }

    private func polar(ox: Double, oy: Double, r: Double, deg: Double) -> CGPoint {
        let rad = deg * .pi / 180
        return CGPoint(x: ox + sin(rad) * r, y: oy - cos(rad) * r)
    }
}
