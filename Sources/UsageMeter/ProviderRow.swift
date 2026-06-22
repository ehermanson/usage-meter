import SwiftUI

/// One provider's section: name + plan badge, its pools, and any stale note.
struct ProviderRow: View {
    let provider: ProviderUsage
    /// A subtle brand-ish accent so providers read as distinct sections; used as
    /// the dot fallback when the provider has no logo.
    let accent: Color
    /// Bundled logo resource name, supplied by the provider definition.
    let logoResource: String?
    /// Show headroom left instead of usage consumed.
    var showRemaining: Bool = false

    /// Source logos are pre-trimmed to their opaque bounds, so a single frame
    /// renders both marks at the same visual size.
    private let logoSize: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Center the logo, name, and plan badge on a shared optical midline.
            // A plain `.center` HStack aligns frame centers, and the badge's
            // capsule padding leaves it sitting visibly low next to the name;
            // `.rowMid` lines up the text's cap-height center instead.
            HStack(alignment: .rowMid, spacing: 6) {
                if let logo = logoImage {
                    Image(nsImage: logo)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: logoSize, height: logoSize)
                        .foregroundStyle(.primary)
                        .alignmentGuide(.rowMid) { $0.height / 2 }
                        .accessibilityHidden(true)
                } else {
                    Circle()
                        .fill(accent)
                        .frame(width: 7, height: 7)
                        .alignmentGuide(.rowMid) { $0.height / 2 }
                        .accessibilityHidden(true)
                }
                Text(provider.name)
                    .font(.system(size: 12, weight: .semibold))
                if let plan = provider.plan {
                    Text(plan)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                }
            }

            ForEach(provider.pools) { pool in
                if let title = pool.title {
                    Text(title)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(pool.windows) { window in
                        WindowBar(window: window, showRemaining: showRemaining)
                    }
                }
            }

            // A provider that just needs setup (tool missing / not signed in) is
            // an expected state, not a failure — show a calm, actionable hint.
            if let setup = provider.setup, provider.allWindows.isEmpty {
                setupHint(setup)
            } else if let note = provider.error {
                // A note shown alongside windows means we're displaying a stale
                // value; with no windows it's a hard error.
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(provider.allWindows.isEmpty ? .red : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func setupHint(_ setup: SetupHint) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(setup.message)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let urlString = setup.url, let url = URL(string: urlString) {
                Link("Set up ↗", destination: url)
                    .font(.system(size: 10, weight: .medium))
            }
        }
    }

    /// The provider's bundled brand logo, loaded once as a tintable template image.
    private var logoImage: NSImage? {
        guard let logoResource else { return nil }
        return ProviderRow.logo(named: logoResource)
    }

    private static func logo(named resource: String) -> NSImage? {
        if let cached = logoCache[resource] { return cached }
        guard let bundle = resourceBundle,
            let url = bundle.url(forResource: resource, withExtension: "png"),
            let image = NSImage(contentsOf: url)
        else { return nil }
        image.isTemplate = true
        logoCache[resource] = image
        return image
    }

    private static var logoCache: [String: NSImage] = [:]

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

private extension VerticalAlignment {
    /// Aligns on a single line of text's optical (cap-height) center rather than
    /// its frame center, so a capsule-padded badge sits level with the name.
    enum RowMid: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat {
            d[.firstTextBaseline] * 0.66
        }
    }

    static let rowMid = VerticalAlignment(RowMid.self)
}
