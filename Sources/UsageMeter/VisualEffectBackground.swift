import SwiftUI

/// Gives the `.window`-style `MenuBarExtra` a translucent, see-through Liquid
/// Glass material like a native menu. SwiftUI doesn't expose window vibrancy, so
/// we make the host window's root `contentView` a glass view with the SwiftUI
/// hosting view nested inside it.
///
/// On macOS 26, only `NSGlassEffectView` actually composites translucently in a
/// MenuBarExtra window — `NSVisualEffectView`'s behind-window blur renders opaque
/// here. We use its frosted `.regular` style so content stays legible over dark
/// windows (`.clear` is more see-through but washes out on dark backgrounds).
///
/// Two non-obvious requirements:
///   * The glass must be the window's *root* content view (a child view always
///     draws above its parent, so a nested blur covers the content or fails to
///     composite). SwiftUI populates the content view asynchronously, so we retry
///     until it's ready, then wrap once.
///   * `isOpaque`/`backgroundColor` must be set *after* swapping the content view
///     — AppKit resets a window's opacity when its content view changes.
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        NSView()  // invisible anchor; only used to reach the host window
    }

    func updateNSView(_ anchor: NSView, context: Context) {
        DispatchQueue.main.async { wrap(anchor: anchor, attempt: 0) }
    }

    private func wrap(anchor: NSView, attempt: Int) {
        guard let window = anchor.window else {
            retry(anchor: anchor, attempt: attempt)
            return
        }

        // Already wrapped on this (or a prior) show — keep it transparent.
        if window.contentView is NSGlassEffectView || window.contentView is NSVisualEffectView {
            makeTransparent(window)
            return
        }

        // Wait until SwiftUI has installed real content to wrap.
        guard let hosting = window.contentView, !hosting.subviews.isEmpty else {
            retry(anchor: anchor, attempt: attempt)
            return
        }

        let glass: NSView
        if #available(macOS 26.0, *) {
            let view = NSGlassEffectView()
            // .regular (frosted) rather than .clear: the frost keeps content
            // legible over dark windows, the way native menus do. .clear is too
            // see-through and washes out on dark backgrounds.
            view.style = .regular
            view.frame = hosting.frame
            view.autoresizingMask = [.width, .height]
            view.contentView = hosting
            glass = view
        } else {
            let view = NSVisualEffectView()
            view.material = .popover
            view.blendingMode = .behindWindow
            view.state = .active
            view.frame = hosting.frame
            view.autoresizingMask = [.width, .height]
            hosting.frame = view.bounds
            hosting.autoresizingMask = [.width, .height]
            view.addSubview(hosting)
            glass = view
        }
        window.contentView = glass

        // Set opacity AFTER swapping contentView — AppKit resets isOpaque on swap.
        makeTransparent(window)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { makeTransparent(window) }
    }

    private func makeTransparent(_ window: NSWindow) {
        window.isOpaque = false
        window.backgroundColor = .clear
    }

    private func retry(anchor: NSView, attempt: Int) {
        guard attempt < 20 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            wrap(anchor: anchor, attempt: attempt + 1)
        }
    }
}
