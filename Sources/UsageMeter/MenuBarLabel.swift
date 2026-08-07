import AppKit

/// One run of the menu-bar title. The store decides *what* to say; the renderer
/// owns the typography, so emphasis travels as a style rather than a font — the
/// labels recede, the window driving the ring reads loudest.
struct MenuBarSegment: Equatable {
    enum Style: Equatable {
        case label  // "5h", "Wk" — small and dimmed
        case primary  // the window the ring is showing
        case secondary  // a supporting window
    }
    let text: String
    let style: Style
}

/// Everything the menu-bar item draws.
struct MenuBarDisplay: Equatable {
    /// How much of the ring is stroked, 0...1. This follows whatever the numbers
    /// say: it grows with usage by default, and drains battery-style when the
    /// user asks for headroom left, matching the dropdown's bars.
    var fraction: Double
    /// Usage consumed, 0...1 — what the ring is *colored* by. Kept separate from
    /// `fraction` so a draining ring still reddens as the limit approaches
    /// instead of cooling off exactly when things get tight.
    var severity: Double
    /// Brand mark drawn inside the ring, or nil to leave the ring empty.
    var logoResource: String?
    var segments: [MenuBarSegment]
}

/// Renders the menu-bar content (brand mark in a usage ring + styled text) into
/// a single `NSImage`.
///
/// The image is *not* a template: the ring carries a usage color, and template
/// mode would flatten it to the menu bar's monochrome tint. That means the caller
/// owns what template rendering would otherwise handle for free — light/dark
/// inversion and the inverted appearance while the item is highlighted — which is
/// why `ink` is a parameter rather than something decided here. See
/// `StatusBarController.ink`.
enum MenuBarRenderer {
    /// Text point size for the menu-bar title. Smaller than the ~13pt system
    /// default that a plain SwiftUI label would be clamped to.
    static let fontSize: CGFloat = 11
    private static let labelFontSize: CGFloat = 10

    private static let itemHeight: CGFloat = 22
    private static let glyphDiameter: CGFloat = 20
    private static let ringWidth: CGFloat = 2.2
    /// A point smaller than the ring could strictly hold. The ring is closed, so
    /// the stroke now wraps the mark on every side, including the top where an
    /// opening used to leave air; trimming the mark puts that clearance back.
    private static let logoDiameter: CGFloat = 10
    private static let glyphTextGap: CGFloat = 6

    /// Gap before a segment that starts a new label/value group, versus the
    /// tighter gap between a label and the value it belongs to.
    private static let groupGap: CGFloat = 6
    private static let pairGap: CGFloat = 3

    /// Draws `display` exactly as given. The animating caller hands in a copy
    /// whose `fraction`/`severity` are the eased values for this frame while the
    /// segments still carry the real numbers — a percentage ticking upward in
    /// the menu bar reads as data churning rather than as a transition.
    /// Main-actor isolated only because it resolves the brand mark through
    /// `BrandLogo`'s caches; the drawing below is pure and stays nonisolated.
    @MainActor
    static func image(_ display: MenuBarDisplay, ink: NSColor) -> NSImage {
        let runs = display.segments.map { attributed($0, ink: ink) }
        let gaps = layoutGaps(display.segments)

        // Every segment gets a slot sized for its widest form, so a value gaining
        // a digit changes nothing about where anything sits: not the item's own
        // width (which would nudge every status item to its left), and not the
        // segments after it (which would jump within the item). The slack shows
        // up as a little extra air before the next group's label, never as
        // movement. Slots are measured once and reused when drawing.
        let slots = display.segments.map { ceil(attributed($0.widest, ink: ink).size().width) }
        let textWidth = zip(gaps, slots).reduce(0) { $0 + $1.0 + $1.1 }
        let width = glyphDiameter + (textWidth > 0 ? glyphTextGap + textWidth : 0)

        // Resolve the mark up front rather than inside the handler below: AppKit
        // may run a drawing handler off the main thread, and `BrandLogo`'s caches
        // are main-actor state. Everything the handler touches is now local.
        let mark = display.logoResource.flatMap { BrandLogo.tinted($0, ink) }

        // `drawingHandler` re-runs per backing scale, so the ring stays crisp
        // when the menu bar moves between a Retina and a non-Retina display.
        // `lockFocus` would bake in whichever scale was current at build time.
        let image = NSImage(
            size: NSSize(width: max(width, 1), height: itemHeight), flipped: false
        ) { _ in
            drawGlyph(display, mark: mark, ink: ink)

            var x = glyphDiameter + glyphTextGap
            for (index, run) in runs.enumerated() {
                x += gaps[index]
                // Left-aligned in its slot, so a label and its value stay tight
                // together and the slack falls at the group boundary.
                run.draw(at: NSPoint(x: x, y: (itemHeight - run.size().height) / 2))
                x += slots[index]
            }
            return true
        }
        return image
    }

    // MARK: - Glyph

    private static func drawGlyph(
        _ display: MenuBarDisplay, mark: NSImage?, ink: NSColor
    ) {
        let center = CGPoint(x: glyphDiameter / 2, y: itemHeight / 2)
        drawRing(
            center: center, radius: glyphDiameter / 2 - ringWidth / 2 - 0.1,
            fraction: display.fraction, color: rampColor(display.severity * 100), ink: ink)

        guard let logo = mark else { return }
        logo.draw(
            in: NSRect(
                x: center.x - logoDiameter / 2, y: center.y - logoDiameter / 2,
                width: logoDiameter, height: logoDiameter),
            from: .zero, operation: .sourceOver, fraction: 1)
    }

    private static func drawRing(
        center: CGPoint, radius: CGFloat, fraction: Double, color: NSColor, ink: NSColor
    ) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }

        ctx.setLineCap(.round)
        ctx.setLineWidth(ringWidth)

        // Closed track, and the fill sweeps clockwise from 12 o'clock. An
        // earlier version left an opening in the track, which put a hole exactly
        // where the eye looks for zero and made the arc read as running the
        // wrong way — a closed ring has one unambiguous origin, the same as the
        // progress rings that wrap an app icon or an avatar.
        let start = CGFloat.pi / 2

        ctx.setStrokeColor(ink.withAlphaComponent(0.18).cgColor)
        ctx.addArc(
            center: center, radius: radius, startAngle: 0, endAngle: .pi * 2,
            clockwise: false)
        ctx.strokePath()

        let filled = max(0, min(1, fraction))
        guard filled > 0.001 else { return }
        ctx.setStrokeColor(color.cgColor)
        ctx.addArc(
            center: center, radius: radius, startAngle: start,
            endAngle: start - .pi * 2 * CGFloat(filled), clockwise: true)
        ctx.strokePath()
    }

    /// Continuous green → amber → red. The stepped thresholds used elsewhere
    /// snap partway through the ring's ease, so the animated arc interpolates
    /// instead. Healthy stays flat green until 55% so the common case doesn't
    /// look like it's already drifting toward a warning.
    static func rampColor(_ percent: Double) -> NSColor {
        let green = NSColor(srgbRed: 0.29, green: 0.78, blue: 0.44, alpha: 1)
        let amber = NSColor(srgbRed: 0.99, green: 0.76, blue: 0.19, alpha: 1)
        let red = NSColor(srgbRed: 0.98, green: 0.35, blue: 0.31, alpha: 1)
        if percent < 55 { return green }
        if percent < 80 { return blend(green, amber, (percent - 55) / 25) }
        return blend(amber, red, (percent - 80) / 20)
    }

    private static func blend(_ a: NSColor, _ b: NSColor, _ t: Double) -> NSColor {
        let t = CGFloat(max(0, min(1, t)))
        return NSColor(
            srgbRed: a.redComponent + (b.redComponent - a.redComponent) * t,
            green: a.greenComponent + (b.greenComponent - a.greenComponent) * t,
            blue: a.blueComponent + (b.blueComponent - a.blueComponent) * t,
            alpha: 1)
    }

    // MARK: - Text

    private static func attributed(_ segment: MenuBarSegment, ink: NSColor) -> NSAttributedString {
        NSAttributedString(string: segment.text, attributes: attributes(segment.style, ink: ink))
    }

    /// Emphasis is carried by size, weight, and alpha rather than by color, so
    /// the hierarchy holds against any menu-bar background.
    private static func attributes(
        _ style: MenuBarSegment.Style, ink: NSColor
    )
        -> [NSAttributedString.Key: Any]
    {
        switch style {
        case .label:
            return [
                .font: NSFont.monospacedDigitSystemFont(ofSize: labelFontSize, weight: .regular),
                .foregroundColor: ink.withAlphaComponent(0.55),
            ]
        case .primary:
            return [
                .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: ink,
            ]
        case .secondary:
            return [
                .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium),
                .foregroundColor: ink.withAlphaComponent(0.75),
            ]
        }
    }

    /// Leading gap for each segment: wider where a new label starts a group,
    /// tighter between a label and the value it introduces.
    private static func layoutGaps(_ segments: [MenuBarSegment]) -> [CGFloat] {
        segments.enumerated().map { index, segment in
            guard index > 0 else { return 0 }
            return segment.style == .label ? groupGap : pairGap
        }
    }

}

extension MenuBarSegment {
    /// The segment at its widest: every digit run in a *value* padded out to
    /// three digits, so "7%" reserves the same width as "100%". Labels are left
    /// alone — "5h" is fixed text that happens to contain a digit.
    var widest: MenuBarSegment {
        guard style != .label else { return self }
        var out = ""
        var run = 0
        func flush() {
            if run > 0 {
                out += String(repeating: "0", count: max(run, 3))
                run = 0
            }
        }
        for character in text {
            if character.isNumber {
                run += 1
            } else {
                flush()
                out.append(character)
            }
        }
        flush()
        return MenuBarSegment(text: out, style: style)
    }
}
