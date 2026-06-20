import SwiftUI

/// A single usage window: label, percentage, a colored progress bar, and reset.
struct WindowBar: View {
    let window: UsageWindow
    /// When true, show headroom left and drain the bar as usage rises (battery
    /// style); otherwise show usage consumed and fill the bar.
    var showRemaining: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
                }
                Spacer()
                Text(Format.percent(displayedPercent))
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
            }

            ProgressView(value: barFraction)
                .progressViewStyle(.linear)
                .tint(barColor)
                .animation(.default, value: window.usedPercent)
                // Counter the linear bar's built-in top padding so it sits snug
                // under the label row above it.
                .padding(.top, -3)
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

    // Color carries meaning here: a panel of calm neutral bars with one amber or
    // red bar tells you exactly where to look. Plenty of headroom stays neutral;
    // color only appears as a limit approaches.
    private var barColor: Color {
        switch window.usedPercent {
        case ..<75: .secondary  // healthy — plenty of headroom
        case ..<90: .yellow  // getting close
        default: .red  // nearly exhausted
        }
    }
}
