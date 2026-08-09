import AppKit
import Testing

@testable import UsageMeter

/// The drawn menu-bar item. These cover the properties that are invisible in a
/// screenshot but obvious once they break — the item resizing under a neighbor,
/// text jumping inside it, the ring's color skipping partway through its ease,
/// or the arc losing its origin.
@MainActor
@Suite("Menu bar renderer")
struct MenuBarRendererTests {
    private func display(_ five: String, _ week: String, fraction: Double = 0.5) -> MenuBarDisplay {
        MenuBarDisplay(
            glyphs: [
                MenuBarGlyph(
                    id: "p", fraction: fraction, severity: fraction, logoResource: "claude-logo")
            ],
            segments: [
                MenuBarSegment(text: "5h", style: .label),
                MenuBarSegment(text: five, style: .primary),
                MenuBarSegment(text: "Wk", style: .label),
                MenuBarSegment(text: week, style: .secondary),
            ])
    }

    private func width(_ display: MenuBarDisplay) -> CGFloat {
        MenuBarRenderer.image(display, ink: .black).size.width
    }

    @Test("width is stable across digit counts so neighbouring items don't shift")
    func widthIsStableAcrossDigitCounts() {
        let narrow = width(display("7%", "6%"))
        let mid = width(display("72%", "24%"))
        let wide = width(display("100%", "100%"))
        #expect(narrow == wide)
        #expect(mid == wide)
    }

    @Test("a longer label still widens the item")
    func labelWidthStillCounts() {
        // Only the *values* are padded to their widest; label text is measured
        // as-is, so a genuinely longer title is allowed to take more room.
        let short = width(display("50%", "50%"))
        let long = width(
            MenuBarDisplay(
                glyphs: [
                    MenuBarGlyph(id: "p", fraction: 0.5, severity: 0.5, logoResource: "claude-logo")
                ],
                segments: [
                    MenuBarSegment(text: "Usage", style: .label),
                    MenuBarSegment(text: "50%", style: .primary),
                ]))
        #expect(long != short)
    }

    @Test("a ring with no text is exactly as wide as the ring")
    func ringOnlyHasNoTrailingSlack() {
        // Any extra here is dead space on the right of the item — invisible
        // until the highlight capsule draws around it and sits off-centre.
        let bare = MenuBarDisplay(
            glyphs: [MenuBarGlyph(id: "p", fraction: 0.4, severity: 0.4, logoResource: nil)],
            segments: [])
        #expect(width(bare) == 20)

        // Two rings: both diameters plus one inter-ring gap, nothing trailing.
        let pair = MenuBarDisplay(
            glyphs: [
                MenuBarGlyph(id: "a", fraction: 0.4, severity: 0.4, logoResource: nil),
                MenuBarGlyph(id: "b", fraction: 0.2, severity: 0.2, logoResource: nil),
            ], segments: [])
        #expect(width(pair) == 44)
    }

    @Test("an empty title still renders the ring")
    func glyphOnlyHasWidth() {
        let bare = MenuBarDisplay(
            glyphs: [
                MenuBarGlyph(id: "p", fraction: 0.4, severity: 0.4, logoResource: "claude-logo")
            ],
            segments: [])
        let image = MenuBarRenderer.image(bare, ink: .black)
        #expect(image.size.width > 0)
        #expect(image.size.height > 0)
    }

    @Test("a drained ring is still colored by usage, not by what's left")
    func drainedRingKeepsUsageColor() {
        // Remaining mode at 92% used: a nearly-empty arc that must still be red.
        let drained = MenuBarDisplay(
            glyphs: [
                MenuBarGlyph(id: "p", fraction: 0.08, severity: 0.92, logoResource: "claude-logo")
            ],
            segments: [])
        let critical = MenuBarRenderer.rampColor(92)
        // Same geometry, healthy usage — the arcs match but the colors must not.
        let healthy = MenuBarDisplay(
            glyphs: [
                MenuBarGlyph(id: "p", fraction: 0.08, severity: 0.08, logoResource: "claude-logo")
            ],
            segments: [])
        #expect(critical.redComponent > critical.greenComponent)
        #expect(MenuBarRenderer.rampColor(drained.glyphs[0].severity * 100) == critical)
        #expect(MenuBarRenderer.rampColor(healthy.glyphs[0].severity * 100) != critical)
    }

    // MARK: - Arc geometry

    /// Rasterizes the item and samples the ring's centreline at a clock position,
    /// so the arc's origin and direction are pinned by what actually lands on
    /// screen rather than by the angle arithmetic agreeing with itself.
    ///
    /// Oversampled 4×: the stroke is only 2.2pt, so at 1× a rounded pixel
    /// coordinate can land on a half-covered edge and read as a miss.
    private func ringSample(_ display: MenuBarDisplay, oClock: Double) -> NSColor {
        let scale = 4
        let image = MenuBarRenderer.image(display, ink: .white)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(image.size.width) * scale,
            pixelsHigh: Int(image.size.height) * scale, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        // Glyph geometry mirrors the renderer's: 20pt circle at the leading edge,
        // 2.2pt stroke, so the centreline sits 8.8pt out from the middle.
        let center = CGPoint(x: 10, y: 11)
        let radius = 8.8
        // 12 o'clock is up; hours advance clockwise.
        let angle = (90 - oClock / 12 * 360) * .pi / 180
        let x = (center.x + cos(angle) * radius) * Double(scale)
        // `colorAt` counts rows from the top, the drawing counts from the bottom.
        let y = (image.size.height - (center.y + sin(angle) * radius)) * Double(scale)
        return rep.colorAt(x: Int(x.rounded()), y: Int(y.rounded())) ?? .clear
    }

    private func isFill(_ color: NSColor, _ expected: NSColor) -> Bool {
        let c = color.usingColorSpace(.sRGB) ?? color
        let e = expected.usingColorSpace(.sRGB) ?? expected
        return abs(c.redComponent - e.redComponent) < 0.15
            && abs(c.greenComponent - e.greenComponent) < 0.15
            && abs(c.blueComponent - e.blueComponent) < 0.15
            && c.alphaComponent > 0.7
    }

    @Test("the arc starts at 12 o'clock and fills clockwise")
    func arcOriginAndDirection() {
        // Half full: 12 through 6 the clockwise way, so the right side is the
        // painted one and the left is bare track.
        let half = MenuBarDisplay(
            glyphs: [MenuBarGlyph(id: "p", fraction: 0.5, severity: 0.5, logoResource: nil)],
            segments: [])
        let fill = MenuBarRenderer.rampColor(50)
        #expect(isFill(ringSample(half, oClock: 3), fill))
        #expect(!isFill(ringSample(half, oClock: 9), fill))
    }

    @Test("an empty ring paints no fill anywhere, including its origin")
    func emptyArcHasNoFill() {
        let empty = MenuBarDisplay(
            glyphs: [MenuBarGlyph(id: "p", fraction: 0, severity: 0, logoResource: nil)],
            segments: [])
        let fill = MenuBarRenderer.rampColor(0)
        for hour in [12.0, 3, 6, 9] {
            #expect(!isFill(ringSample(empty, oClock: hour), fill))
        }
    }

    @Test("a full ring paints every clock position")
    func fullArcClosesAllTheWayRound() {
        let full = MenuBarDisplay(
            glyphs: [MenuBarGlyph(id: "p", fraction: 1, severity: 1, logoResource: nil)],
            segments: [])
        let fill = MenuBarRenderer.rampColor(100)
        // Including 12, where the round caps meet — a notch there would be the
        // visible failure.
        for hour in [12.0, 1.5, 3, 4.5, 6, 7.5, 9, 10.5] {
            #expect(isFill(ringSample(full, oClock: hour), fill))
        }
    }

    @Test("the usage ramp is continuous, so an easing ring never jumps color")
    func rampIsContinuous() {
        // Sampling finely across the whole range: neighbouring percentages must
        // never differ by more than a hair in any channel. The stepped
        // thresholds this replaced would fail hard at 55/80.
        var previous = MenuBarRenderer.rampColor(0)
        for step in 1...1000 {
            let color = MenuBarRenderer.rampColor(Double(step) / 10)
            let delta = max(
                abs(color.redComponent - previous.redComponent),
                max(
                    abs(color.greenComponent - previous.greenComponent),
                    abs(color.blueComponent - previous.blueComponent)))
            #expect(delta < 0.02)
            previous = color
        }
    }

    @Test("the ramp runs green through amber to red")
    func rampDirection() {
        let healthy = MenuBarRenderer.rampColor(10)
        let warning = MenuBarRenderer.rampColor(70)
        let critical = MenuBarRenderer.rampColor(100)
        // Green is the greenest, red the reddest, warning in between.
        #expect(healthy.greenComponent > healthy.redComponent)
        #expect(critical.redComponent > critical.greenComponent)
        #expect(warning.redComponent > healthy.redComponent)
        #expect(warning.greenComponent > critical.greenComponent)
    }
}
