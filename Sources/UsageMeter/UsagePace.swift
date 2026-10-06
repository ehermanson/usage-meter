import Foundation

/// How a window's consumption compares with the time that has passed in it:
/// 50% used one hour into a five-hour window is burning far faster than the
/// window can sustain, while 50% used four hours in leaves room to spare.
/// Pure and clock-injectable so the view can recompute it as time passes (the
/// verdict drifts with the clock even when the data doesn't) and tests can pin
/// the moment.
struct UsagePace: Equatable {
    enum Status: Equatable {
        /// Usage is outrunning the clock; at this rate the limit arrives early.
        case aheadOfPace
        /// Usage is roughly tracking the clock.
        case onPace
        /// Usage is comfortably behind the clock.
        case roomToSpare
    }

    let status: Status
    /// Fraction of the window's time already elapsed, 0...1. The bar's pace
    /// marker sits here.
    let elapsedFraction: Double
    /// The percent a perfectly even spend would have used by now.
    let expectedPercent: Double
    /// Where usage lands at reset if the average rate so far holds.
    let projectedPercent: Double
    /// When the limit is hit at the current rate — only set when ahead of pace,
    /// and then always before the reset (that's what ahead means here).
    let limitAt: Date?

    // Thresholds. The ratio (`projected`) says which way usage is heading;
    // the point gap (`used − expected`) keeps the early-window ratio from
    // crying wolf — 2% used at 1% elapsed projects to 200% but is noise —
    // while a real burst (30% used at 3% elapsed) clears both easily.

    /// Projected end-of-window percent at or above which usage is ahead.
    static let aheadProjection: Double = 110
    /// Projected end-of-window percent at or below which there's room to spare.
    static let roomProjection: Double = 85
    /// Minimum gap, in percentage points between used and expected, before
    /// either non-neutral verdict is given.
    static let minPointGap: Double = 3
    /// How far the time remaining may exceed the window's length before the
    /// data is treated as inconsistent (clock skew, a rounded duration).
    static let durationTolerance: TimeInterval = 120

    /// Nil when pace can't be stated honestly: no reset or length to measure
    /// against, a reset already passed, a reset further out than the window
    /// is long (bad data), or a limit already hit (pace is moot).
    init?(window: UsageWindow, now: Date = Date()) {
        guard let reset = window.resetAt, let duration = window.duration, duration > 0
        else { return nil }
        let remaining = reset.timeIntervalSince(now)
        guard remaining > 0, remaining <= duration + Self.durationTolerance else { return nil }
        let used = max(0, window.usedPercent)
        guard used < 100 else { return nil }

        // Clamp so a reset a few seconds beyond the window (within tolerance)
        // reads as the window's very start rather than negative time.
        let elapsed = max(0, duration - remaining)
        let fraction = elapsed / duration
        let expected = fraction * 100
        let delta = used - expected
        // At the window's first instant nothing has elapsed; any use at all
        // is then an unbounded rate, so let the projection say so and leave
        // the point gap to decide whether it matters.
        let projected = elapsed > 0 ? used / fraction : (used > 0 ? .infinity : 0)

        let status: Status
        if projected >= Self.aheadProjection, delta >= Self.minPointGap {
            status = .aheadOfPace
        } else if projected <= Self.roomProjection, delta <= -Self.minPointGap {
            status = .roomToSpare
        } else {
            status = .onPace
        }

        self.status = status
        self.elapsedFraction = fraction
        self.expectedPercent = expected
        self.projectedPercent = projected
        // Remaining headroom divided by the average burn rate so far. Ahead
        // implies used > 0 and elapsed > 0 (a zero-elapsed burst has no rate
        // to divide by, so it gets no time estimate rather than "now").
        if status == .aheadOfPace, elapsed > 0, used > 0 {
            let ratePerSecond = used / elapsed
            self.limitAt = now.addingTimeInterval((100 - used) / ratePerSecond)
        } else {
            self.limitAt = nil
        }
    }

    /// The short caption under the bar: "Ahead of pace · limit in 1h 5m",
    /// "On pace", "Room to spare · on track for ~40%". The projection runs the
    /// same direction as the row's number — in remaining mode "~60% left at
    /// reset", so it never reads as contradicting a "95% left" beside it.
    func caption(showRemaining: Bool = false, now: Date = Date()) -> String {
        switch status {
        case .aheadOfPace:
            guard let limitAt else { return "Ahead of pace" }
            return "Ahead of pace · limit in \(Format.resetDuration(limitAt, now: now))"
        case .onPace:
            return "On pace"
        case .roomToSpare:
            return showRemaining
                ? "Room to spare · ~\(Format.percent(projectedLeft)) left at reset"
                : "Room to spare · on track for ~\(Format.percent(projectedPercent))"
        }
    }

    /// The full sentence for the tooltip and VoiceOver.
    func sentence(showRemaining: Bool = false, now: Date = Date()) -> String {
        switch status {
        case .aheadOfPace:
            guard let limitAt else {
                return "Ahead of pace: usage is running faster than this window allows."
            }
            return "Ahead of pace: at this rate you'll hit the limit in about "
                + "\(Format.resetDuration(limitAt, now: now)), before it resets."
        case .onPace:
            return "On pace: usage is tracking the time elapsed in this window."
        case .roomToSpare:
            return showRemaining
                ? "Room to spare: at this rate you'll have about "
                    + "\(Format.percent(projectedLeft)) left when it resets."
                : "Room to spare: at this rate you'll use about "
                    + "\(Format.percent(projectedPercent)) before it resets."
        }
    }

    /// Headroom left at reset if the current rate holds.
    private var projectedLeft: Double { max(0, 100 - projectedPercent) }
}
