import AppKit
import Observation
import QuartzCore
import SwiftUI

/// Owns the menu-bar item and the dropdown panel, and—crucially—computes the
/// panel's position itself instead of leaving it to SwiftUI's `MenuBarExtra`.
///
/// `MenuBarExtra(.window)` places its window once, from the content's size at
/// open time, and gets it wrong whenever the geometry shifts afterward (an async
/// data refresh adding rows, the "update available" row appearing, or a custom
/// glass `contentView` swap). That produced the panel covering or misaligning
/// against the menu bar. Here the panel's *top* is pinned just below the
/// button's on-screen rect and the panel grows downward, so it can never overlap
/// the menu bar regardless of height; horizontal position is clamped to the
/// screen. Any later content resize re-runs the same placement.
@MainActor
final class StatusBarController {
    private let store: UsageStore
    private let statusItem: NSStatusItem
    private let panel: NSPanel
    private let hostingView: ContentHostingView<MenuContentView>

    private var eventMonitor: Any?

    /// Gap between the menu bar (button's bottom edge) and the panel's top.
    private let gap: CGFloat = 6
    /// Keep the panel this far from the screen's left/right/bottom edges.
    private let edgeMargin: CGFloat = 8

    /// True while the panel is open. AppKit won't draw a status item's highlight
    /// for us here, so the open state is painted by hand — see `applyHighlight`.
    private var isHighlighted = false

    /// How each ring is drawn right now, eased toward the store's real values and
    /// keyed by provider so a ring stays matched to its own data when the set of
    /// them changes. Arc length and color travel together on one timer, so the
    /// color can't land on its final shade while the arc is still halfway there.
    /// A ring absent from this map starts at zero, which is what makes the first
    /// data of the session — and any provider appearing later — sweep up from
    /// empty rather than snapping into place.
    private var ringValues: [String: RingValues] = [:]
    private var ringAnimation: RingAnimation?
    private var ringTimer: Timer?
    private let ringDuration: CFTimeInterval = 0.55

    private struct RingValues: Equatable {
        var fraction: Double
        var severity: Double
        static let empty = RingValues(fraction: 0, severity: 0)
    }

    private struct RingAnimation {
        let from: [String: RingValues]
        let to: [String: RingValues]
        let startedAt: CFTimeInterval
    }

    init(store: UsageStore) {
        self.store = store
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        hostingView = ContentHostingView(rootView: MenuContentView(store: store))
        panel = Self.makePanel(content: hostingView)

        configureButton()
        observeMenuBar()
        observeAppearance()

        // Sweep the ring up from empty to whatever the store already has (the
        // last-good snapshot seeded from disk), so launch reads as the meter
        // filling rather than as a value appearing from nowhere.
        animateRing(to: store.menuBarDisplay)

        // Re-place the panel whenever the SwiftUI content changes height (async
        // refresh, the update row appearing) so the top stays anchored under the
        // menu bar and it grows/shrinks downward rather than drifting.
        hostingView.onContentSizeChange = { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.positionPanel()
        }

        // Dev affordance: `--open-panel` pops the dropdown right after launch so
        // it can be screenshotted without assistive access to click the item.
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--open-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.show()
            }
        }

        // `--snapshot <path>` renders the panel to a PNG (after giving the
        // usage fetch a moment) and quits — self-rendering, so it needs no
        // screen-recording permission. Exits nonzero if the capture fails.
        if let i = args.firstIndex(of: "--snapshot"), args.indices.contains(i + 1) {
            let path = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self else { return }
                // Snapshot implies an open panel: `show()` lays the content out
                // and sizes the panel to fit, so the capture is never the stale
                // 280×200 the panel was constructed with.
                if !self.panel.isVisible { self.show() }
                do {
                    try self.snapshotPanel(to: path)
                } catch {
                    FileHandle.standardError.write(
                        Data("snapshot failed (\(path)): \(error)\n".utf8))
                    exit(EXIT_FAILURE)
                }
                NSApplication.shared.terminate(nil)
            }
        }

        // `--snapshot-item <path>` does the same for the menu-bar item itself.
        if let i = args.firstIndex(of: "--snapshot-item"), args.indices.contains(i + 1) {
            let path = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self else { return }
                do {
                    try self.snapshotItem(to: path)
                } catch {
                    FileHandle.standardError.write(
                        Data("snapshot-item failed (\(path)): \(error)\n".utf8))
                    exit(EXIT_FAILURE)
                }
                NSApplication.shared.terminate(nil)
            }
        }
    }

    /// This object lives as long as the app, so teardown is belt-and-braces —
    /// but an orphaned repeating timer would keep firing against a dead ease,
    /// and it costs one line to rule out. The appearance probe needs no cleanup:
    /// the button owns it, and it only holds a weak reference back.
    deinit {
        ringTimer?.invalidate()
    }

    private enum SnapshotError: Error {
        case captureUnavailable  // no content view / no bitmap rep
        case pngEncodingFailed
    }

    /// Writes the menu-bar item art to `path` as a light/dark/highlighted strip.
    ///
    /// Same reason `--snapshot` exists: the status item can't be screenshotted
    /// without screen-recording permission. Since the art is hand-drawn and not
    /// a template, this is the only way to see all three ink states — the ones
    /// AppKit would otherwise have handled — actually rendered.
    private func snapshotItem(to path: String) throws {
        let display = animatedDisplay
        let variants: [(NSColor, NSColor)] = [
            (NSColor(srgbRed: 0.93, green: 0.93, blue: 0.94, alpha: 1), .black),
            (NSColor(srgbRed: 0.16, green: 0.16, blue: 0.18, alpha: 1), .white),
            (NSColor(srgbRed: 0.28, green: 0.30, blue: 0.34, alpha: 1), .white),
        ]
        let images = variants.map { MenuBarRenderer.image(display, ink: $0.1) }
        let cell = NSSize(width: (images.map(\.size.width).max() ?? 40) + 32, height: 34)
        let size = NSSize(width: cell.width * CGFloat(variants.count), height: cell.height)

        // Oversampled so 11pt text and a 2.2pt stroke are legible when the PNG is
        // viewed at 1:1. Named so the pixel dimensions and `rep.size` can't drift.
        let scale: CGFloat = 3
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB,
                bytesPerRow: 0, bitsPerPixel: 0)
        else { throw SnapshotError.captureUnavailable }
        rep.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for (index, variant) in variants.enumerated() {
            let frame = NSRect(
                x: cell.width * CGFloat(index), y: 0, width: cell.width, height: cell.height)
            variant.0.setFill()
            frame.fill()
            let image = images[index]
            image.draw(
                in: NSRect(
                    x: frame.midX - image.size.width / 2, y: frame.midY - image.size.height / 2,
                    width: image.size.width, height: image.size.height),
                from: .zero, operation: .sourceOver, fraction: 1)
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw SnapshotError.pngEncodingFailed
        }
        try data.write(to: URL(fileURLWithPath: path))
    }

    /// Renders the panel's content view into a PNG at `path`.
    private func snapshotPanel(to path: String) throws {
        guard let view = panel.contentView,
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { throw SnapshotError.captureUnavailable }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw SnapshotError.pngEncodingFailed
        }
        try data.write(to: URL(fileURLWithPath: path))
    }

    // MARK: - Menu-bar button

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(togglePanel)
        render()
    }

    /// The color the mark and text are drawn in.
    ///
    /// A template image would get this for free, but the ring carries a usage
    /// color and template mode would flatten it, so it's handled here. The menu
    /// bar has its own appearance — it can be dark while the app is light — so
    /// this reads the button's `effectiveAppearance` rather than the app's.
    ///
    /// Unaffected by the open state: the highlight we draw is a wash tinted from
    /// this same color, so the content stays legible against it either way.
    private var ink: NSColor {
        let appearance = statusItem.button?.effectiveAppearance ?? NSApp.effectiveAppearance
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark ? .white : .black
    }

    /// The store's display with the ring swapped for wherever the ease has got
    /// to. The segments stay as-is, so the text never lags the real numbers.
    private var animatedDisplay: MenuBarDisplay {
        var display = store.menuBarDisplay
        display.glyphs = display.glyphs.map { glyph in
            var eased = glyph
            let values = ringValues[glyph.id] ?? .empty
            eased.fraction = values.fraction
            eased.severity = values.severity
            return eased
        }
        return display
    }

    private func render() {
        guard let button = statusItem.button else { return }
        button.image = MenuBarRenderer.image(animatedDisplay, ink: ink)
        // The image carries no text AppKit can read, so the flat title is the
        // accessible label.
        //
        // `toolTip` is set for the same reason, but don't count on it: macOS
        // doesn't surface tooltips for menu-bar extras here, with the string on
        // the button and an explicit tooltip rect both making no difference. It
        // stays because it's free and correct — the dropdown is what actually
        // has to carry the numbers for the ring-only styles.
        button.setAccessibilityLabel(store.menuBarTitle)
        button.toolTip = store.menuBarTooltip
        applyHighlight(to: button)
    }

    /// Paints the open state ourselves, as a rounded wash behind the whole item.
    ///
    /// `highlight(_:)` and `isHighlighted` both turn out to be dead ends here:
    /// the flag reads `true` for as long as the panel is open and AppKit still
    /// draws nothing, so there is no amount of re-asserting that would help.
    /// Painting the button's own layer covers its full frame — wider than our
    /// image, which stops at the content — so the wash lines up with the item's
    /// real bounds the way a native highlight does.
    private func applyHighlight(to button: NSStatusBarButton) {
        button.wantsLayer = true
        // Fully rounded, matching how the system draws menu-bar selection —
        // derived from the button's height rather than pinned to a number, so it
        // stays a capsule if the menu bar's metrics ever change.
        button.layer?.cornerRadius = button.bounds.height / 2
        // AppKit draws its own highlight while the button is held, which
        // composites with this one and then lifts with the mouse. That step is
        // fixed in absolute terms — it's the system's contribution, not ours —
        // so a heavier wash can't remove it, only make it a smaller share of
        // what's on screen, which is what actually reads as less of a flash.
        button.layer?.backgroundColor =
            isHighlighted
            ? ink.withAlphaComponent(0.26).cgColor
            : NSColor.clear.cgColor
    }

    /// Keep the menu-bar image in sync with the store. `@Observable` fires
    /// `onChange` once before each mutation, so we re-register to keep tracking.
    private func observeMenuBar() {
        withObservationTracking {
            _ = store.menuBarDisplay
            _ = store.menuBarTitle
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.animateRing(to: self.store.menuBarDisplay)
                self.render()
                self.observeMenuBar()
            }
        }
    }

    /// Re-render whenever the item's appearance changes.
    ///
    /// Watching for a light/dark *theme* switch isn't enough: since Big Sur the
    /// menu bar takes its appearance from the desktop picture, so a light-mode
    /// user with a dark wallpaper gets a dark menu bar — `effectiveAppearance`
    /// on the button becomes `.darkAqua` and no theme notification ever fires.
    /// Changing the wallpaper or dragging the item to a display with a different
    /// appearance are the same story. Since the image isn't a template, missing
    /// any of those means drawing black on dark until the next refresh happens
    /// to re-render — an effectively invisible menu-bar item.
    ///
    /// So let AppKit say when it changed, via the one hook that covers every
    /// cause: a zero-sized view parented to the button, which inherits the
    /// button's appearance and is told each time it resolves differently.
    private func observeAppearance() {
        guard let button = statusItem.button else { return }
        let probe = AppearanceProbeView()
        probe.onAppearanceChange = { [weak self] in self?.render() }
        button.addSubview(probe)
    }

    // MARK: - Ring animation

    /// Ease the ring to a new state. Only the ring moves — the text shows the
    /// real number immediately, because a percentage counting upward in the menu
    /// bar reads as data churning rather than as a transition.
    ///
    /// Each frame re-rasterizes the item and reassigns `button.image`, so this
    /// runs only across a change and stops at the end. Nothing animates at rest:
    /// a permanent loop would keep the app awake for a decoration.
    private func animateRing(to display: MenuBarDisplay) {
        let target = Dictionary(
            uniqueKeysWithValues: display.glyphs.map { glyph in
                (
                    glyph.id,
                    RingValues(
                        fraction: max(0, min(1, glyph.fraction)),
                        severity: max(0, min(1, glyph.severity)))
                )
            })
        // Nothing to do when every ring is already where it should be. Compared
        // against the rings the target actually names, so a provider dropping out
        // of view doesn't count as a change worth animating.
        let settled = target.allSatisfy { id, value in
            let current = ringValues[id] ?? .empty
            return abs(current.fraction - value.fraction) <= 0.001
                && abs(current.severity - value.severity) <= 0.001
        }
        guard !settled else {
            ringValues = ringValues.filter { target.keys.contains($0.key) }
            return
        }

        ringAnimation = RingAnimation(
            from: ringValues, to: target, startedAt: CACurrentMediaTime())
        guard ringTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.stepRing() }
        }
        // `.common` rather than the default mode: a refresh can land while the
        // user is dragging a window or holding a native menu open, and in those
        // tracking modes a default-mode timer stops firing — the ease would
        // freeze mid-sweep and then snap when tracking ended.
        RunLoop.main.add(timer, forMode: .common)
        ringTimer = timer
    }

    private func stepRing() {
        guard let animation = ringAnimation else { return stopRingAnimation() }
        let progress = min(1, (CACurrentMediaTime() - animation.startedAt) / ringDuration)
        // Ease-out cubic: quick off the mark, settling gently onto the value.
        let eased = 1 - pow(1 - progress, 3)
        for (id, to) in animation.to {
            let from = animation.from[id] ?? .empty
            ringValues[id] = RingValues(
                fraction: from.fraction + (to.fraction - from.fraction) * eased,
                severity: from.severity + (to.severity - from.severity) * eased)
        }
        render()
        if progress >= 1 {
            // Land exactly on the targets, and forget any ring that's no longer
            // shown so a provider coming back later sweeps up from empty again.
            ringValues = animation.to
            stopRingAnimation()
        }
    }

    private func stopRingAnimation() {
        ringTimer?.invalidate()
        ringTimer = nil
        ringAnimation = nil
    }

    // MARK: - Show / hide

    @objc private func togglePanel() {
        panel.isVisible ? hide() : show()
    }

    private func show() {
        // Per-open work lives here, not in the content view's `onAppear`: the
        // hosting view stays parented to the persistent panel, so SwiftUI sees
        // it "appear" exactly once for the app's lifetime — `orderOut`/
        // `orderFront` never re-fire it. Opening refetches only when the data
        // has gone stale, so a quick open right after a timer tick reuses what's
        // already shown.
        if store.isStale {
            Task { await store.refresh() }
        }
        Task { await UpdateChecker.shared.check() }

        // Lay the content out before measuring so the very first open is placed
        // from the real fitting size, not a stale/zero one.
        hostingView.layoutSubtreeIfNeeded()
        positionPanel()
        panel.makeKeyAndOrderFront(nil)
        isHighlighted = true
        render()

        // Close the panel on any click outside of it.
        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self else { return }
            let point = NSEvent.mouseLocation
            // A global monitor is supposed to exclude our own app's events, but
            // on some macOS versions a click on the status item arrives here
            // anyway. Hiding on it would be wrong twice over: the button's own
            // action fires next, sees a hidden panel, and reopens it — so the
            // click appears to do nothing at all. Toggling is `togglePanel`'s
            // job; this monitor only handles genuine outside clicks.
            if let frame = self.buttonHitFrame, frame.contains(point) { return }
            self.hide()
        }
    }

    /// The status-item button's rect in screen coordinates, valid on whichever
    /// display and Space the menu bar currently occupies.
    private var buttonScreenFrame: NSRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    /// `buttonScreenFrame` grown to meet the top of the screen. The reported rect
    /// stops a few points shy of the edge, but a click in that strip is still a
    /// click on our item — and treating it as an outside click is what makes the
    /// panel close and immediately reopen.
    ///
    /// Only closes a small, plausible gap. If the button isn't sitting against
    /// the menu bar at all — hidden menu bar, an off-screen or not-yet-placed
    /// item — reaching for the screen edge would claim a tall strip of the
    /// display and start swallowing genuine outside clicks, so that case keeps
    /// the button's own frame.
    private var buttonHitFrame: NSRect? {
        guard let frame = buttonScreenFrame else { return nil }
        guard let screen = statusItem.button?.window?.screen else { return frame }
        let gap = screen.frame.maxY - frame.maxY
        guard gap > 0, gap < 12 else { return frame }
        return NSRect(
            x: frame.minX, y: frame.minY, width: frame.width, height: frame.height + gap)
    }

    private func hide() {
        panel.orderOut(nil)
        isHighlighted = false
        render()
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    // MARK: - Positioning

    private func positionPanel() {
        guard let buttonWindow = statusItem.button?.window,
            let buttonFrame = buttonScreenFrame
        else { return }

        let size = hostingView.fittingSize
        guard size.width > 0, size.height > 0 else { return }

        let screen = buttonWindow.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? buttonFrame

        // Anchor the panel's TOP just under the button and extend downward, so
        // the panel never overlaps the menu bar no matter how tall it is.
        var originY = buttonFrame.minY - gap - size.height
        let minY = visible.minY + edgeMargin
        if originY < minY { originY = minY }  // very tall content on a short screen

        // Center under the button, then clamp within the visible frame so the
        // panel can't spill off either screen edge.
        var originX = buttonFrame.midX - size.width / 2
        let minX = visible.minX + edgeMargin
        let maxX = visible.maxX - size.width - edgeMargin
        if maxX >= minX { originX = min(max(originX, minX), maxX) }

        panel.setFrame(
            NSRect(origin: NSPoint(x: originX, y: originY), size: size), display: true)
    }

    // MARK: - Panel construction

    private static func makePanel(content: NSView) -> NSPanel {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Show above full-screen apps and follow the active Space, like a menu.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = makeGlass(wrapping: content)
        return panel
    }

    /// Wrap the SwiftUI content in the same translucent material a native menu
    /// uses. Owning the panel lets us build this once, synchronously, instead of
    /// the async `contentView`-swap dance the old `MenuBarExtra` window needed.
    private static func makeGlass(wrapping content: NSView) -> NSView {
        let radius: CGFloat = 12
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular  // frosted: keeps content legible over dark windows
            glass.cornerRadius = radius
            glass.contentView = content
            content.autoresizingMask = [.width, .height]

            // `cornerRadius` rounds the glass, but its backing layer stays a
            // square rect — so the panel's auto-computed window shadow traces a
            // square and leaves a hard, squared-off edge under the bottom
            // corners. Clip through a masked container (the VEV path below gets
            // this for free via `masksToBounds`) so the shadow follows the
            // rounded shape.
            let clip = NSView()
            clip.wantsLayer = true
            clip.layer?.cornerRadius = radius
            clip.layer?.masksToBounds = true
            glass.autoresizingMask = [.width, .height]
            clip.addSubview(glass)
            return clip
        } else {
            let vev = NSVisualEffectView()
            vev.material = .popover
            vev.blendingMode = .behindWindow
            vev.state = .active
            vev.wantsLayer = true
            vev.layer?.cornerRadius = radius
            vev.layer?.masksToBounds = true
            content.autoresizingMask = [.width, .height]
            content.frame = vev.bounds
            vev.addSubview(content)
            return vev
        }
    }
}

/// A zero-sized view whose only job is to report appearance changes. Parented to
/// the status-item button, it inherits the button's appearance, so AppKit calls
/// `viewDidChangeEffectiveAppearance` for every cause — theme switch, wallpaper
/// making the menu bar dark in light mode, or a move to another display. Zero
/// frame so it can't affect layout or swallow the button's clicks.
private final class AppearanceProbeView: NSView {
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}

/// A borderless window can't become key by default, which leaves every control
/// inside rendering in its *inactive* appearance — switches stay gray whether
/// on or off. Opting in restores active-state tinting; combined with
/// `.nonactivatingPanel` the panel takes key status without activating the app,
/// exactly like a native menu.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// `NSHostingView` that reports when its SwiftUI content's ideal size changes,
/// so the panel can be re-placed to keep its top edge anchored under the menu
/// bar (a plain window would otherwise grow upward over the bar).
final class ContentHostingView<Content: View>: NSHostingView<Content> {
    var onContentSizeChange: (() -> Void)?
    private var lastReportedSize: NSSize = .zero

    override func layout() {
        super.layout()
        let size = fittingSize
        if size != lastReportedSize {
            lastReportedSize = size
            onContentSizeChange?()
        }
    }
}
