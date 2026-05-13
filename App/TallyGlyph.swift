import SwiftUI
import AppKit

/// Tally's brand mark: two horizontal pill bars (the equals sign) with a small
/// downward-pointing heading-bug triangle sitting on top of the upper bar.
///
/// Designed as a SwiftUI Shape so it renders crisp at any size, in any colour.
/// Used as the toolbar pane-switcher glyph (in tinted form) and as the menu
/// bar status-item template (matches the macOS app icon design).
struct TallyGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height

        // Geometric proportions taken from the 1024×1024 master in
        // icon/renders/Tally-Concept-2-Equals-HeadingBug-1024.png.
        let barWidth = w * 0.65
        let barHeight = h * 0.13
        let barX = (w - barWidth) / 2

        // Vertical placement: roughly centred, with a small gap between bars.
        let gap = barHeight * 0.9
        let topBarY = h / 2 - barHeight - gap / 2
        let bottomBarY = h / 2 + gap / 2

        let barCorner = barHeight / 2
        path.addRoundedRect(
            in: CGRect(x: barX, y: topBarY, width: barWidth, height: barHeight),
            cornerSize: CGSize(width: barCorner, height: barCorner)
        )
        path.addRoundedRect(
            in: CGRect(x: barX, y: bottomBarY, width: barWidth, height: barHeight),
            cornerSize: CGSize(width: barCorner, height: barCorner)
        )

        // Heading-bug triangle pointing down at the top bar.
        let bugWidth = barWidth * 0.22
        let bugHeight = bugWidth * 0.7
        let bugCenterX = rect.midX
        let bugTopY = topBarY - bugHeight * 1.1
        path.move(to: CGPoint(x: bugCenterX - bugWidth / 2, y: bugTopY))
        path.addLine(to: CGPoint(x: bugCenterX + bugWidth / 2, y: bugTopY))
        path.addLine(to: CGPoint(x: bugCenterX, y: bugTopY + bugHeight))
        path.closeSubpath()

        return path
    }
}

extension TallyGlyph {
    /// Bitmap version of the glyph for places where SwiftUI Shape-in-Menu
    /// label renders unreliably (the toolbar pane-switcher Menu would
    /// otherwise collapse to a hairline). Renders at 2× for retina crispness.
    static func nsImage(size: CGFloat = 18, color: NSColor) -> NSImage {
        let pt = NSSize(width: size, height: size)
        let img = NSImage(size: pt, flipped: false) { rect in
            let path = NSBezierPath()
            let w = rect.width, h = rect.height

            let barWidth = w * 0.65
            let barHeight = h * 0.13
            let barX = (w - barWidth) / 2
            let gap = barHeight * 0.9
            let topBarY = h / 2 - barHeight - gap / 2
            let bottomBarY = h / 2 + gap / 2
            let barCorner = barHeight / 2

            path.append(NSBezierPath(roundedRect:
                NSRect(x: barX, y: topBarY, width: barWidth, height: barHeight),
                xRadius: barCorner, yRadius: barCorner))
            path.append(NSBezierPath(roundedRect:
                NSRect(x: barX, y: bottomBarY, width: barWidth, height: barHeight),
                xRadius: barCorner, yRadius: barCorner))

            // Heading-bug triangle just above the top bar.
            let bugWidth = barWidth * 0.22
            let bugHeight = bugWidth * 0.75
            let centerX = rect.midX
            let bugTopY = topBarY + barHeight + bugHeight * 0.6
            let bugTip = NSPoint(x: centerX, y: topBarY + barHeight + 0.4)
            let tri = NSBezierPath()
            tri.move(to: NSPoint(x: centerX - bugWidth / 2, y: bugTopY))
            tri.line(to: NSPoint(x: centerX + bugWidth / 2, y: bugTopY))
            tri.line(to: bugTip)
            tri.close()
            path.append(tri)

            color.setFill()
            path.fill()
            return true
        }
        return img
    }
}
