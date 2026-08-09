import Foundation
import Testing

@testable import UsageMeter

/// A failed refresh falls back on the last good snapshot. These cover *when*
/// that snapshot stops being worth showing, and how the row admits its age —
/// the difference between "the endpoint blinked" and "this is last week's data".
@Suite("Stale last-good values")
struct StaleValueTests {
    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    private func snapshot(agedBy age: TimeInterval?) -> ProviderUsage {
        var usage = ProviderUsage.ok(
            "Gemini",
            pools: [
                UsagePool(
                    title: nil, windows: [UsageWindow(label: "Daily", usedPercent: 0, resetAt: nil)]
                )
            ])
        usage.capturedAt = age.map { now.addingTimeInterval(-$0) }
        return usage
    }

    @Test("a snapshot from minutes ago is still worth showing")
    func freshSurvives() {
        #expect(!UsageStore.isExpired(snapshot(agedBy: 300), now: now))
    }

    @Test("a snapshot well past the cap is dropped rather than rendered as current")
    func ancientExpires() {
        #expect(UsageStore.isExpired(snapshot(agedBy: UsageStore.maxStaleAge + 3600), now: now))
        #expect(UsageStore.isExpired(snapshot(agedBy: 10 * 24 * 3600), now: now))
    }

    @Test("the boundary sits exactly at the shipped cap")
    func boundary() {
        #expect(!UsageStore.isExpired(snapshot(agedBy: UsageStore.maxStaleAge - 1), now: now))
        #expect(UsageStore.isExpired(snapshot(agedBy: UsageStore.maxStaleAge), now: now))
    }

    @Test("an unstamped snapshot is expired — its age can't be known")
    func unstampedExpires() {
        // Nothing assigned a capture date (the persisted-store migration stamps
        // one where it can). Trusting an unknowable age is what this check stops.
        #expect(UsageStore.isExpired(snapshot(agedBy: nil), now: now))
    }

    @Test("a legacy snapshot's age is bounded by its own reset dates")
    func legacyBoundByReset() {
        // The store-wide refresh date says "just now" (the old build rewrote it
        // every pass), but the snapshot's only window reset nine days ago — the
        // value must predate that reset, so the tighter bound wins and expires it.
        let longPast = now.addingTimeInterval(-9 * 24 * 3600)
        let windows = [UsageWindow(label: "Daily", usedPercent: 0, resetAt: longPast)]
        let bound = UsageStore.legacyCaptureBound(lastPass: now, windows: windows)
        #expect(bound == longPast)
        var usage = snapshot(agedBy: nil)
        usage.capturedAt = bound
        #expect(UsageStore.isExpired(usage, now: now))
    }

    @Test("a legacy snapshot with future resets keeps the refresh date as its bound")
    func legacyBoundByLastPass() {
        let futureReset = now.addingTimeInterval(3600)
        let windows = [UsageWindow(label: "5h", usedPercent: 40, resetAt: futureReset)]
        let recent = now.addingTimeInterval(-600)
        #expect(UsageStore.legacyCaptureBound(lastPass: recent, windows: windows) == recent)
        // No evidence at all → nil, which isExpired treats as too old to trust.
        #expect(UsageStore.legacyCaptureBound(lastPass: nil, windows: []) == nil)
    }

    @Test("a recent value is described tersely")
    func terseNote() {
        let captured = now.addingTimeInterval(-(UsageStore.ageWorthNaming - 1))
        #expect(UsageStore.staleNote(captured, now: now) == "showing last value")
    }

    @Test("a value old enough to matter names its age instead")
    func agedNote() {
        let anHour = now.addingTimeInterval(-UsageStore.ageWorthNaming)
        #expect(UsageStore.staleNote(anHour, now: now) == "showing value from 1h ago")
        #expect(
            UsageStore.staleNote(now.addingTimeInterval(-5 * 3600), now: now)
                == "showing value from 5h ago")
    }
}
