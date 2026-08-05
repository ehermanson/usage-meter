import SwiftUI

/// A single usage window: label, percentage, a colored progress bar, and reset.
struct WindowBar: View {
    let window: UsageWindow
    /// The provider's brand accent — fills the bar while usage is healthy.
    var accent: Color = .accentColor
    /// When true, show headroom left and drain the bar as usage rises (battery
    /// style); otherwise show usage consumed and fill the bar.
    var showRemaining: Bool = false

    private let barHeight: CGFloat = 5

    var body: some View {
        // Hovering the row reveals the absolute reset moment — the compact
        // "4d 14h" answers "how long", the tooltip answers "when exactly".
        if let reset = window.resetAt {
            rows.help(Format.absoluteReset(reset))
        } else {
            rows
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Label, reset countdown, and percentage share one row so each window
            // reads as two compact lines instead of three.
            HStack(spacing: 6) {
                Text(window.label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if let reset = window.resetAt {
                    Text(Format.resetDuration(reset))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                } else if let detail = window.detail {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                Spacer()
                // Name the direction the number runs — without it, 13% in used
                // mode and 87% in remaining mode are indistinguishable at a
                // glance, and nothing on the row says which mode is active.
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(Format.percent(displayedPercent))
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                    Text(showRemaining ? "left" : "used")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }

            // A custom capsule instead of `ProgressView(.linear)`: a slightly
            // thicker track with a soft brand-colored gradient fill, so the
            // panel has some life without abandoning the native material.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    if barFraction > 0 {
                        Capsule()
                            .fill(barFill)
                            .frame(width: max(barHeight, geo.size.width * barFraction))
                    }
                }
            }
            .frame(height: barHeight)
            .animation(.default, value: window.usedPercent)
        }
        // Read the label, percentage, and reset as a single VoiceOver element.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(window.label)
        .accessibilityValue(accessibilityValue)
    }

    private var displayedPercent: Double {
        showRemaining ? window.remainingPercent : window.usedPercent
    }

    /// The bar always represents what the number shows: fills with usage in the
    /// default mode, drains toward empty as headroom shrinks in remaining mode.
    private var barFraction: Double {
        showRemaining ? 1 - window.clampedFraction : window.clampedFraction
    }

    private var accessibilityValue: String {
        var value = "\(Format.percent(displayedPercent)) \(showRemaining ? "left" : "used")"
        if let reset = window.resetAt {
            value += ", \(Format.relativeReset(reset))"
        }
        return value
    }

    // Color still carries meaning: healthy bars wear the provider's accent, and
    // amber/red take over as a limit approaches — so a bar changing color is
    // still the signal to look.
    private var barColor: Color {
        switch window.usedPercent {
        case ..<75: accent  // healthy — plenty of headroom
        case ..<90: .yellow  // getting close
        default: .red  // nearly exhausted
        }
    }

    /// A gentle leading-to-trailing deepening of the state color; enough depth
    /// to not look flat, not so much that it reads as a rainbow.
    private var barFill: LinearGradient {
        LinearGradient(
            colors: [barColor.opacity(0.65), barColor],
            startPoint: .leading, endPoint: .trailing)
    }
}
