import AppKit

/// Loads the bundled provider marks.
///
/// Every source PNG is a single solid shape over transparency — Codex's `>_` is
/// a knockout rather than white fill — so the marks tint cleanly to any color
/// and ship as one asset instead of a light and a dark variant. The dropdown
/// lets AppKit apply the template tint; the menu bar draws into an image it
/// composes itself and so needs `tinted(_:_:)` to do the same fill by hand.
/// Main-actor isolated: these are AppKit images behind mutable static caches,
/// and every caller already draws on the main thread.
@MainActor
enum BrandLogo {
    /// The mark as a template image, for callers that let AppKit tint it.
    static func image(named resource: String) -> NSImage? {
        if let cached = cache[resource] { return cached }
        guard let bundle = resourceBundle,
            let url = bundle.url(forResource: resource, withExtension: "png"),
            let image = NSImage(contentsOf: url)
        else { return nil }
        image.isTemplate = true
        cache[resource] = image
        return image
    }

    /// The mark filled with a solid color. `sourceAtop` masks the fill by the
    /// existing alpha, which is the same thing template rendering does — so
    /// antialiased edges and interior knockouts both survive.
    ///
    /// Drawn through a handler rather than `lockFocus`, which would rasterize
    /// once at whatever the main screen's scale happened to be and then serve
    /// that from the cache forever — blurry on a Retina menu bar whenever the
    /// first tint landed on a 1× display. The handler re-runs per destination
    /// scale, matching how the ring around it is drawn, so a cache entry is
    /// scale-independent.
    static func tinted(_ resource: String, _ color: NSColor) -> NSImage? {
        guard let base = image(named: resource) else { return nil }
        let key = TintKey(resource: resource, color: color)
        if let cached = tintCache[key] { return cached }

        let out = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tintCache[key] = out
        return out
    }

    private struct TintKey: Hashable {
        let resource: String
        let color: NSColor
    }

    private static var cache: [String: NSImage] = [:]
    private static var tintCache: [TintKey: NSImage] = [:]

    /// Locates the SwiftPM resource bundle ourselves instead of using the
    /// generated `Bundle.module`, which looks for the bundle at the `.app` root
    /// and otherwise `fatalError`s against a build-machine path baked in at
    /// compile time — crashing every installed copy. In a packaged app the
    /// bundle sits in `Contents/Resources`; in dev it's next to the executable.
    private static let resourceBundle: Bundle? = {
        let name = "UsageMeter_UsageMeter.bundle"
        let bases = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
            Bundle(for: BundleToken.self).resourceURL,
            Bundle(for: BundleToken.self).bundleURL,
        ]
        for base in bases {
            if let url = base?.appendingPathComponent(name),
                let bundle = Bundle(url: url)
            {
                return bundle
            }
        }
        return nil
    }()
}

private final class BundleToken {}
