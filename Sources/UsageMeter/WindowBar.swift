import SwiftUI

/// A single usage window: label, percentage, a colored progress bar, and reset.
struct WindowBar: View {
    let window: UsageWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(window.label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(Format.percent(window.usedPercent))
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
            }

            // Keep the reset hint tucked right under its bar so the trio reads
            // as one group; separation from the next window comes from ProviderRow.
            VStack(alignment: .leading, spacing: 0) {
                ProgressView(value: window.clampedFraction)
                    .progressViewStyle(.linear)
                    .tint(barColor)
                    .animation(.default, value: window.usedPercent)

                if let reset = window.resetAt {
                    Text(Format.relativeReset(reset))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        // Counter the linear bar's built-in bottom padding so the
                        // hint sits snug against the bar above it.
                        .padding(.top, -3)
                }
            }
            // Counter the linear bar's built-in top padding so it sits snug under
            // the label/percent row above it.
            .padding(.top, -3)
        }
        // Read the label, percentage, and reset as a single VoiceOver element.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(window.label)
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        var value = "\(Format.percent(window.usedPercent)) used"
        if let reset = window.resetAt {
            value += ", \(Format.relativeReset(reset))"
        }
        return value
    }

    private var barColor: Color {
        switch window.usedPercent {
        case ..<60: .green   // healthy
        case ..<90: .yellow  // getting close
        default: .red        // nearly exhausted
        }
    }
}
