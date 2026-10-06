import Foundation
import Testing

@testable import UsageMeter

@Suite("Usage pace")
struct UsagePaceTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let hour: TimeInterval = 3600

    /// A window of `duration` hours with `elapsed` hours gone and `used` percent spent.
    private func pace(
        used: Double, elapsed: Double, of duration: Double = 5
    ) -> UsagePace? {
        let window = UsageWindow(
            label: "5h", usedPercent: used,
            resetAt: now.addingTimeInterval((duration - elapsed) * hour),
            duration: duration * hour)
        return UsagePace(window: window, now: now)
    }

    @Test("1h into a 5h window at 50% is ahead, hitting the limit 1h later")
    func userExample() throws {
        let p = try #require(pace(used: 50, elapsed: 1))
        #expect(p.status == .aheadOfPace)
        #expect(abs(p.expectedPercent - 20) < 1e-9)
        #expect(abs(p.projectedPercent - 250) < 1e-9)
        // 50% per hour, 50% left: one more hour.
        #expect(p.limitAt == now.addingTimeInterval(hour))
        #expect(p.caption(now: now) == "Ahead of pace · limit in 1h 0m")
        #expect(
            p.sentence(now: now)
                == "Ahead of pace: at this rate you'll hit the limit in about 1h 0m, before it resets."
        )
    }

    @Test("time to limit scales with the remaining headroom")
    func timeToLimit() throws {
        // 2h into 5h at 60%: 30%/h, 40% left -> 80 minutes.
        let p = try #require(pace(used: 60, elapsed: 2))
        #expect(p.status == .aheadOfPace)
        let limitAt = try #require(p.limitAt)
        #expect(abs(limitAt.timeIntervalSince(now) - 80 * 60) < 1e-6)
        #expect(p.caption(now: now) == "Ahead of pace · limit in 1h 20m")
    }

    @Test("usage tracking the clock is on pace, with no time to limit")
    func onPace() throws {
        let p = try #require(pace(used: 52, elapsed: 2.5))
        #expect(p.status == .onPace)
        #expect(p.limitAt == nil)
        #expect(p.caption(now: now) == "On pace")
    }

    @Test("usage well behind the clock has room to spare, with its projection")
    func roomToSpare() throws {
        // 4 days into a week at 20%: projects to 35%.
        let p = try #require(pace(used: 20, elapsed: 96, of: 168))
        #expect(p.status == .roomToSpare)
        #expect(p.limitAt == nil)
        #expect(p.caption(now: now) == "Room to spare · on track for ~35%")
        // In remaining mode the projection runs the same way as the row's number.
        #expect(p.caption(showRemaining: true, now: now) == "Room to spare · ~65% left at reset")
        #expect(
            p.sentence(showRemaining: true, now: now)
                == "Room to spare: at this rate you'll have about 65% left when it resets.")
    }

    @Test("an early ratio without a real point gap is on pace, not ahead")
    func earlyNoiseGuard() throws {
        // 2% used 3 minutes into 5h (1% elapsed) projects to 200%.
        let p = try #require(pace(used: 2, elapsed: 0.05))
        #expect(p.projectedPercent > 110)
        #expect(p.status == .onPace)
    }

    @Test("an early real burst still warns")
    func earlyBurst() throws {
        // 30% used 9 minutes into 5h (3% elapsed).
        let p = try #require(pace(used: 30, elapsed: 0.15))
        #expect(p.status == .aheadOfPace)
        #expect(p.limitAt != nil)
    }

    @Test("an untouched window early on is on pace, not room to spare")
    func earlyIdle() throws {
        // 0% used 6 minutes in: 2 points behind, inside the guard.
        #expect(try #require(pace(used: 0, elapsed: 0.1)).status == .onPace)
        // Later on, idle is genuinely room to spare.
        #expect(try #require(pace(used: 0, elapsed: 2)).status == .roomToSpare)
    }

    @Test("no pace once the limit is hit")
    func atLimit() {
        #expect(pace(used: 100, elapsed: 2) == nil)
        #expect(pace(used: 104, elapsed: 2) == nil)
    }

    @Test("no pace once the reset has passed")
    func pastReset() {
        #expect(pace(used: 40, elapsed: 5) == nil)
        #expect(pace(used: 40, elapsed: 6) == nil)
    }

    @Test("no pace without a duration or a reset")
    func missingInputs() {
        let noDuration = UsageWindow(
            label: "Overage", usedPercent: 40, resetAt: now.addingTimeInterval(hour))
        #expect(UsagePace(window: noDuration, now: now) == nil)
        let noReset = UsageWindow(label: "Usage", usedPercent: 40, resetAt: nil, duration: hour)
        #expect(UsagePace(window: noReset, now: now) == nil)
    }

    @Test("a reset further out than the window is long is bad data, beyond a small tolerance")
    func resetBeyondDuration() throws {
        #expect(pace(used: 10, elapsed: -1) == nil)
        // A minute of skew still reads as the window's start.
        let skewed = try #require(pace(used: 0, elapsed: -1.0 / 60))
        #expect(skewed.elapsedFraction == 0)
        #expect(skewed.status == .onPace)
    }
}
