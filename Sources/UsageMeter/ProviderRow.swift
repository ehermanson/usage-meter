import SwiftUI

/// One provider's section: name + plan badge, its pools, and any stale note.
struct ProviderRow: View {
    let provider: ProviderUsage

    /// A subtle brand-ish accent so the two providers read as distinct sections.
    private var accent: Color {
        switch provider.name.lowercased() {
        case "claude": return .orange
        case "codex": return .teal
        default: return .accentColor
        }
    }

    /// Source logos are pre-trimmed to their opaque bounds, so a single frame
    /// renders both marks at the same visual size.
    private let logoSize: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let logo = ProviderRow.logo(for: provider.name) {
                    Image(nsImage: logo)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: logoSize, height: logoSize)
                        .foregroundStyle(.primary)
                        .accessibilityHidden(true)
                } else {
                    Circle()
                        .fill(accent)
                        .frame(width: 7, height: 7)
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
                        WindowBar(window: window)
                    }
                }
            }

            // A note shown alongside windows means we're displaying a stale
            // value; with no windows it's a hard error.
            if let note = provider.error {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(provider.allWindows.isEmpty ? .red : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The provider's bundled brand logo, loaded once as a tintable template image.
    private static func logo(for name: String) -> NSImage? {
        let resource: String
        switch name.lowercased() {
        case "claude": resource = "claude-logo"
        case "codex": resource = "codex-logo"
        default: return nil
        }
        if let cached = logoCache[resource] { return cached }
        guard let url = Bundle.module.url(forResource: resource, withExtension: "png"),
            let image = NSImage(contentsOf: url)
        else { return nil }
        image.isTemplate = true
        logoCache[resource] = image
        return image
    }

    private static var logoCache: [String: NSImage] = [:]
}
