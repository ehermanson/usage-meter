import SwiftUI

/// A single usage window: label, percentage, a colored progress bar, and reset.
struct WindowBar: View {
    let window: UsageWindow
    /// The provider's brand accent — fills the bar while usage is healthy.
    var accent: Color = .accentColor
    /// When true, show headroom left and drain the bar as usage rises (battery
    /// style); otherwise show usage consumed and fill the bar.
    var showRemaining: Bool = false
    /// False when the row shows a carried-forward (stale) snapshot. Pace
    /// compares the percent with the clock, and an old percent against the
    /// current clock drifts toward "room to spare" as time passes without new
    /// usage being seen — a reassurance the data can't back up. So stale rows
    /// show no pace at all rather than a verdict about a past moment.
    var showPace: Bool = true

    private let barHeight: CGFloat = 6

    var body: some View {
        if let reset = window.resetAt {
            // Everything time-dependent here has to redraw itself as the clock
            // moves: the window's value is unchanged between refreshes (same
            // reset moment, same percent), so plain views would be recomputed
            // only on a data change and freeze at whatever "now" they were
            // last drawn with — the countdown, and the pace verdict and marker,
            // which drift with elapsed time too. A minute-ticking TimelineView
            // recomputes them all against the current wall clock regardless.
            TimelineView(.everyMinute) { context in
                let pace = showPace ? UsagePace(window: window, now: context.date) : nil
                // Hovering the row reveals the absolute reset moment — the
                // compact "4d 14h" answers "how long", the tooltip answers
                // "when exactly" — and, when there's a pace, the full sentence
                // the caption abbreviates.
                rows(now: context.date, pace: pace)
                    .help(tooltip(reset: reset, pace: pace, now: context.date))
            }
        } else {
            rows(now: nil, pace: nil)
        }
    }

    private func tooltip(reset: Date, pace: UsagePace?, now: Date) -> String {
        let when = Format.absoluteReset(reset, now: now)
        guard let pace else { return when }
        return "\(when)\n\(pace.sentence(showRemaining: showRemaining, now: now))"
    }

    /// `now` is nil for windows without a reset, which have no countdown or
    /// pace to compute.
    private func rows(now: Date?, pace: UsagePace?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            // Label, reset countdown, and percentage share one row so each window
            // reads as two compact lines instead of three. The label carries the
            // row's identity, so it sits in primary ink; the countdown is the
            // supporting fact and steps back a shade and a size.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(window.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.85))
                if let reset = window.resetAt, let now {
                    Text(Format.resetDuration(reset, now: now))
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
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                    Text(showRemaining ? "left" : "used")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }

            // The caption needs real air under the bar: the pace tick overhangs
            // the track by 2pt, so a tighter stack leaves the text pressed
            // against the tick. 7pt clears it by a visible ~5pt while staying
            // well under the 10pt between windows, so the caption still reads
            // as this bar's, not as a prefix to the next row's header.
            VStack(alignment: .leading, spacing: 7) {
                bar(pace: pace)
                if let pace, let now {
                    paceCaption(pace, now: now)
                }
            }
        }
        // Read the label, percentage, reset, and pace as a single VoiceOver element.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(window.label)
        .accessibilityValue(accessibilityValue(now: now, pace: pace))
    }

    /// Ahead of pace is the signal, so it alone takes a color — orange, apart
    /// from the bar's yellow/red, which say "close to the limit" rather than
    /// "burning fast". The calm verdicts stay in tertiary ink. Color alone
    /// isn't enough, though: under Claude's orange bar an orange caption reads
    /// as brand, not warning, and color-blind readers get nothing from it. So
    /// ahead also leads with a small warning glyph — sized under the text's
    /// cap height and baseline-aligned, so the line is no taller than a calm
    /// one and rows don't shift as the verdict changes.
    private func paceCaption(_ pace: UsagePace, now: Date) -> some View {
        let ahead = pace.status == .aheadOfPace
        return HStack(alignment: .firstTextBaseline, spacing: 3) {
            if ahead {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 8, weight: .semibold))
            }
            Text(pace.caption(showRemaining: showRemaining, now: now))
                .font(.system(size: 9.5, weight: ahead ? .medium : .regular))
                .monospacedDigit()
                .lineLimit(1)
        }
        .foregroundStyle(ahead ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
    }

    private func bar(pace: UsagePace?) -> some View {
        // A custom capsule instead of `ProgressView(.linear)`: a slightly
        // thicker track with a soft brand-colored gradient fill, so the
        // panel has some life without abandoning the native material. A
        // hairline inside the track keeps the empty part from dissolving
        // into the card on the glass material.
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.07))
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.04)))
                if barFraction > 0 {
                    Capsule()
                        .fill(barFill)
                        .frame(width: max(barHeight, geo.size.width * barFraction))
                }
                if let pace {
                    paceMarker(pace, width: geo.size.width)
                }
            }
        }
        .frame(height: barHeight)
        .animation(.default, value: window.usedPercent)
    }

    /// A thin tick where an even spend would have the bar right now, so fill
    /// running past it reads as ahead at a glance. It overhangs the track a
    /// little so it stays legible over both the fill and the empty part, and
    /// a hairline halo in the panel's own background separates it from a fill
    /// of similar lightness, in either appearance.
    private func paceMarker(_ pace: UsagePace, width: CGFloat) -> some View {
        // The remaining-mode bar drains from full, so the even-spend point
        // drains with it.
        let fraction = showRemaining ? 1 - pace.elapsedFraction : pace.elapsedFraction
        let markerWidth: CGFloat = 2
        // Keep the tick inside the track at the very ends of the window.
        let x = min(max(0, width * fraction - markerWidth / 2), width - markerWidth)
        return Capsule()
            .fill(Color.primary.opacity(0.6))
            .overlay(
                Capsule().strokeBorder(
                    Color(nsColor: .windowBackgroundColor).opacity(0.5), lineWidth: 0.5)
            )
            .frame(width: markerWidth, height: barHeight + 4)
            .offset(x: x)
    }

    private var displayedPercent: Double {
        showRemaining ? window.remainingPercent : window.usedPercent
    }

    /// The bar always represents what the number shows: fills with usage in the
    /// default mode, drains toward empty as headroom shrinks in remaining mode.
    private var barFraction: Double {
        showRemaining ? 1 - window.clampedFraction : window.clampedFraction
    }

    private func accessibilityValue(now: Date?, pace: UsagePace?) -> String {
        var value = "\(Format.percent(displayedPercent)) \(showRemaining ? "left" : "used")"
        if let reset = window.resetAt {
            value += ", \(Format.relativeReset(reset, now: now ?? Date()))"
        }
        if let pace, let now {
            value += ". \(pace.sentence(showRemaining: showRemaining, now: now))"
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
