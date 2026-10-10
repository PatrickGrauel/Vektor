import SwiftUI
import VektorAviation

/// CG envelope plot: the POH polygon plus the takeoff → landing → zero-fuel
/// CG track. Shared by the macOS and iPad apps (VektorPad's project.yml
/// pulls this file in), so it only relies on `VektorTheme` members both
/// targets define.
struct WBEnvelopeChart: View {
    let envelope: [WBProfile.Point]
    let conditions: [WeightBalance.Condition]

    var body: some View {
        Canvas { context, size in
            draw(in: &context, size: size)
        }
        .accessibilityElement()
        .accessibilityLabel("CG envelope chart")
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let pts = envelope.map { ($0.cg, $0.weight) }
        let cond = conditions.filter { $0.result.totalWeight > 0 }.map { ($0.result.cg, $0.result.totalWeight) }
        let all = pts + cond
        guard !all.isEmpty else { return }

        var minX = all.map(\.0).min()!, maxX = all.map(\.0).max()!
        var minY = all.map(\.1).min()!, maxY = all.map(\.1).max()!
        if maxX - minX < 1 { minX -= 1; maxX += 1 }
        if maxY - minY < 100 { minY -= 100; maxY += 100 }
        let padX = (maxX - minX) * 0.08, padY = (maxY - minY) * 0.08
        minX -= padX; maxX += padX; minY -= padY; maxY += padY

        let left: CGFloat = 52, bottom: CGFloat = 26, top: CGFloat = 10, right: CGFloat = 12
        let w = size.width - left - right, h = size.height - top - bottom
        guard w > 0, h > 0 else { return }
        func map(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: left + CGFloat((x - minX) / (maxX - minX)) * w,
                    y: top + h - CGFloat((y - minY) / (maxY - minY)) * h)
        }

        // Axes + ticks
        var axes = Path()
        axes.move(to: CGPoint(x: left, y: top))
        axes.addLine(to: CGPoint(x: left, y: top + h))
        axes.addLine(to: CGPoint(x: left + w, y: top + h))
        context.stroke(axes, with: .color(VektorTheme.muted.opacity(0.6)), lineWidth: 1)
        for i in 0...4 {
            let x = minX + (maxX - minX) * Double(i) / 4
            let y = minY + (maxY - minY) * Double(i) / 4
            context.draw(Text(String(format: "%.1f", x)).font(.system(size: 9)).foregroundStyle(VektorTheme.muted),
                         at: CGPoint(x: map(x, minY).x, y: top + h + 4), anchor: .top)
            context.draw(Text(String(format: "%.0f", y)).font(.system(size: 9)).foregroundStyle(VektorTheme.muted),
                         at: CGPoint(x: left - 4, y: map(minX, y).y), anchor: .trailing)
        }

        // Envelope polygon
        if pts.count >= 2 {
            var poly = Path()
            poly.move(to: map(pts[0].0, pts[0].1))
            for p in pts.dropFirst() { poly.addLine(to: map(p.0, p.1)) }
            poly.closeSubpath()
            context.fill(poly, with: .color(VektorTheme.accent.opacity(0.12)))
            context.stroke(poly, with: .color(VektorTheme.accent), lineWidth: 1.5)
        }

        // CG track across the flight
        if cond.count >= 2 {
            var track = Path()
            track.move(to: map(cond[0].0, cond[0].1))
            for p in cond.dropFirst() { track.addLine(to: map(p.0, p.1)) }
            context.stroke(track, with: .color(VektorTheme.text.opacity(0.5)),
                           style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        for c in conditions where c.result.totalWeight > 0 {
            let p = map(c.result.cg, c.result.totalWeight)
            let ok = c.result.inEnvelope == true
            let colour = ok ? VektorTheme.statusGood : VektorTheme.statusBad
            context.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(colour))
            let tag: String
            switch c.kind {
            case .takeoff: tag = "TO"
            case .landing: tag = "LDG"
            case .zeroFuel: tag = "ZF"
            }
            context.draw(Text(tag).font(.system(size: 9, weight: .semibold)).foregroundStyle(colour),
                         at: CGPoint(x: p.x + 6, y: p.y), anchor: .leading)
        }
    }
}
