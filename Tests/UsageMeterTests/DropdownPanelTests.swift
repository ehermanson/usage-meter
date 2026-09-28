import AppKit
import Testing

@testable import UsageMeter

/// The dropdown holds its top edge under the menu bar through any frame
/// change that fits below it, whichever of AppKit's entry points the change
/// comes through.
@MainActor
@Suite("Dropdown panel")
struct DropdownPanelTests {
    private func makePanel() -> DropdownPanel {
        DropdownPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 200),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    }

    @Test("unanchored, a frame is taken as given")
    func unanchored() {
        let panel = makePanel()
        panel.setFrame(NSRect(x: 40, y: 50, width: 280, height: 300), display: false)
        #expect(panel.frame == NSRect(x: 40, y: 50, width: 280, height: 300))
    }

    @Test("any size is placed hanging from the anchor", arguments: [false, true])
    func pinsTopEdge(animate: Bool) {
        let panel = makePanel()
        panel.anchor = DropdownPanel.Anchor(top: 900, x: 100, minY: 20)
        func set(_ frame: NSRect) {
            if animate {
                panel.setFrame(frame, display: false, animate: true)
            } else {
                panel.setFrame(frame, display: false)
            }
        }

        set(NSRect(x: 0, y: 0, width: 280, height: 300))
        #expect(panel.frame == NSRect(x: 100, y: 600, width: 280, height: 300))

        // Growing and shrinking both move the bottom edge, never the top.
        set(NSRect(x: 500, y: 700, width: 280, height: 420))
        #expect(panel.frame == NSRect(x: 100, y: 480, width: 280, height: 420))
        set(NSRect(x: 500, y: 700, width: 280, height: 250))
        #expect(panel.frame == NSRect(x: 100, y: 650, width: 280, height: 250))

        // Taller than the room below the anchor: the bottom stops at `minY`.
        set(NSRect(x: 0, y: 0, width: 280, height: 950))
        #expect(panel.frame == NSRect(x: 100, y: 20, width: 280, height: 950))
    }

    @Test("a content resize from inside the window is pinned too")
    func contentResize() {
        let panel = makePanel()
        panel.anchor = DropdownPanel.Anchor(top: 900, x: 100, minY: 20)
        panel.setContentSize(NSSize(width: 280, height: 360))
        #expect(panel.frame == NSRect(x: 100, y: 540, width: 280, height: 360))
    }
}
