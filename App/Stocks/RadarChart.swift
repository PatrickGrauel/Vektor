import SwiftUI

/// Six-axis radar / spider chart. Pure SwiftUI Canvas — no Charts or
/// third-party drawing dependency.
///
/// Inputs are the same `AxisScore` array the scorecard renders, in their
/// natural axis order. N/A scores (unprofitable companies) draw a hollow
/// point at the centre and a thin dashed spoke so the gap is visible
/// rather than silently filled with a zero.
struct RadarChart: View {
    let axes: [AxisScore]
    /// Side length of the square canvas. Caller picks; the chart self-pads.
    var side: CGFloat = 280

    var body: some View {
        Canvas { context, size in
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 - 28
            let n = max(axes.count, 1)
            let axisColour = TallyTheme.divider
            let labelColour = TallyTheme.muted
            let fillColour = TallyTheme.accent.opacity(0.25)
            let strokeColour = TallyTheme.accent

            // 1. Gridlines at 2/4/6/8/10
            for step in [2, 4, 6, 8, 10] {
                let r = radius * CGFloat(step) / 10
                var path = Path()
                for i in 0..<n {
                    let angle = angleFor(i: i, n: n)
                    let p = CGPoint(x: centre.x + r * cos(angle),
                                    y: centre.y + r * sin(angle))
                    if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                path.closeSubpath()
                context.stroke(path, with: .color(axisColour), lineWidth: 0.5)
            }

            // 2. Spokes
            for i in 0..<n {
                let angle = angleFor(i: i, n: n)
                let p = CGPoint(x: centre.x + radius * cos(angle),
                                y: centre.y + radius * sin(angle))
                var path = Path()
                path.move(to: centre)
                path.addLine(to: p)
                context.stroke(path, with: .color(axisColour), lineWidth: 0.5)
            }

            // 3. Data polygon — N/A axes collapse to centre.
            var dataPath = Path()
            for i in 0..<n {
                let s = axes[i].score ?? 0
                let r = radius * CGFloat(s) / 10
                let angle = angleFor(i: i, n: n)
                let p = CGPoint(x: centre.x + r * cos(angle),
                                y: centre.y + r * sin(angle))
                if i == 0 { dataPath.move(to: p) } else { dataPath.addLine(to: p) }
            }
            dataPath.closeSubpath()
            context.fill(dataPath, with: .color(fillColour))
            context.stroke(dataPath, with: .color(strokeColour), lineWidth: 1.5)

            // 4. Data points — solid for scored, hollow for N/A.
            for i in 0..<n {
                let angle = angleFor(i: i, n: n)
                let s = axes[i].score ?? 0
                let r = radius * CGFloat(s) / 10
                let p = CGPoint(x: centre.x + r * cos(angle),
                                y: centre.y + r * sin(angle))
                let dot = Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3,
                                                 width: 6, height: 6))
                if axes[i].score == nil {
                    context.stroke(dot, with: .color(labelColour), lineWidth: 1)
                } else {
                    context.fill(dot, with: .color(strokeColour))
                }
            }

            // 5. Axis labels — placed just outside the outer ring, with
            //    enough padding that descenders don't clip.
            for i in 0..<n {
                let angle = angleFor(i: i, n: n)
                let r = radius + 18
                let p = CGPoint(x: centre.x + r * cos(angle),
                                y: centre.y + r * sin(angle))
                let text = Text(axes[i].axis.short)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(labelColour)
                context.draw(text, at: p)
            }
        }
        .frame(width: side, height: side)
        .accessibilityLabel("Radar chart of six DCA axis scores")
    }

    /// Place the first axis straight up (12 o'clock), then walk clockwise.
    private func angleFor(i: Int, n: Int) -> CGFloat {
        let stride = (2 * .pi) / CGFloat(n)
        return -.pi / 2 + stride * CGFloat(i)
    }
}
