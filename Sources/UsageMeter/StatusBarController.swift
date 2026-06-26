import AppKit
import Observation
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

    init(store: UsageStore) {
        self.store = store
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        hostingView = ContentHostingView(rootView: MenuContentView(store: store))
        panel = Self.makePanel(content: hostingView)

        configureButton()
        observeMenuBar()

        // Re-place the panel whenever the SwiftUI content changes height (async
        // refresh, the update row appearing) so the top stays anchored under the
        // menu bar and it grows/shrinks downward rather than drifting.
        hostingView.onContentSizeChange = { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.positionPanel()
        }
    }

    // MARK: - Menu-bar button

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.image = MenuBarRenderer.image(icon: store.menuBarIcon, title: store.menuBarTitle)
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(togglePanel)
    }

    /// Keep the menu-bar image in sync with the store. `@Observable` fires
    /// `onChange` once before each mutation, so we re-register to keep tracking.
    private func observeMenuBar() {
        withObservationTracking {
            _ = store.menuBarIcon
            _ = store.menuBarTitle
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.statusItem.button?.image = MenuBarRenderer.image(
                    icon: self.store.menuBarIcon, title: self.store.menuBarTitle)
                self.observeMenuBar()
            }
        }
    }

    // MARK: - Show / hide

    @objc private func togglePanel() {
        panel.isVisible ? hide() : show()
    }

    private func show() {
        // Lay the content out before measuring so the very first open is placed
        // from the real fitting size, not a stale/zero one.
        hostingView.layoutSubtreeIfNeeded()
        positionPanel()
        panel.makeKeyAndOrderFront(nil)
        statusItem.button?.highlight(true)

        // Close the panel on any click outside of it.
        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.hide()
        }
    }

    private func hide() {
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    // MARK: - Positioning

    private func positionPanel() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }

        let size = hostingView.fittingSize
        guard size.width > 0, size.height > 0 else { return }

        // The button's actual on-screen rect — valid on whichever display and
        // Space the menu bar currently lives on.
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
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
        let panel = NSPanel(
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
            return glass
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
