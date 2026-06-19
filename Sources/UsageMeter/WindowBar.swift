import SwiftUI

/// A single usage window: label, percentage, a colored progress bar, and reset.
struct WindowBar: View {
    let window: UsageWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(window.label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(Format.percent(window.usedPercent))
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
            }

            ProgressView(value: window.clampedFraction)
                .progressViewStyle(.linear)
                .tint(barColor)

            if let reset = window.resetAt {
                Text(Format.relativeReset(reset))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var barColor: Color {
        switch window.usedPercent {
        case ..<60: .green   // healthy
        case ..<90: .yellow  // getting close
        default: .red        // nearly exhausted
        }
    }
}
