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
    /// Where a free-reset redeem stands for this provider, and how to start
    /// one. Only providers that hand out reset credits get a `redeem`.
    var resetState: UsageStore.ResetState = .idle
    var redeem: (() -> Void)? = nil
    /// The "are you sure?" step between the button and the redeem.
    @State private var confirmingReset = false

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
                        WindowBar(window: window, accent: accent, showRemaining: showRemaining)
                    }
                }
            }

            // Free resets sit right under the bars they can wipe. The line
            // stays up through the outcome note even if the last credit was
            // just spent, so the verdict has somewhere to land.
            if provider.hasWindows, provider.resetCredits != nil || resetState != .idle {
                resetLine
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

    /// "3 free resets   [Reset now]". A click swaps the
    /// line for an inline confirm rather than a modal: the panel is a
    /// non-activating menu, and a modal alert can't take key status from it —
    /// AppKit just beeps. The line then shows the redeem's progress and its
    /// outcome in the same spot.
    @ViewBuilder
    private var resetLine: some View {
        Group {
            switch resetState {
            case .redeeming:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Resetting…")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            case .note(let note):
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .idle:
                if let credits = provider.resetCredits {
                    if confirmingReset {
                        resetConfirm(credits)
                    } else {
                        HStack(spacing: 6) {
                            // Count over expiry, two short lines: stacked, neither
                            // has to share its width with the button.
                            VStack(alignment: .leading, spacing: 1) {
                                Text(Format.resetCredits(credits))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                if let expiry = Format.resetCreditExpiry(credits) {
                                    Text(expiry)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                        .help(
                                            credits.earliestExpiry.map {
                                                $0.formatted(date: .long, time: .shortened)
                                            } ?? "")
                                }
                            }
                            .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 4)
                            if redeem != nil {
                                Button("Reset now") { confirmingReset = true }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .font(.system(size: 10, weight: .medium))
                                    .help(
                                        "Spend one free reset to clear your current "
                                            + "\(provider.name) limits")
                            }
                        }
                    }
                }
            }
        }
        .padding(.top, 2)
        // A confirm left open across a redeem or a refetch shouldn't linger.
        .onChange(of: resetState) { _, _ in confirmingReset = false }
        .onChange(of: provider.resetCredits) { _, _ in confirmingReset = false }
    }

    /// The reset spends a finite credit and can't be undone, so it takes a
    /// second, deliberate click. The destructive choice is the prominent one
    /// only because it's the one the user just asked for; Cancel sits first.
    private func resetConfirm(_ credits: ResetCredits) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(
                "Spend 1 of \(credits.available) free reset\(credits.available == 1 ? "" : "s")? "
                    + "This clears your current \(provider.name) limits."
            )
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Button("Cancel") { confirmingReset = false }
                    .buttonStyle(.bordered)
                Button("Reset") {
                    confirmingReset = false
                    redeem?()
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
            .font(.system(size: 10, weight: .medium))
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

    /// The provider's bundled brand logo, loaded once as a tintable template
    /// image. Shared with the menu-bar renderer via `BrandLogo`.
    private var logoImage: NSImage? {
        guard let logoResource else { return nil }
        return BrandLogo.image(named: logoResource)
    }
}

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
