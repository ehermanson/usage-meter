import Foundation
import Testing

@testable import UsageMeter

@Suite("Format helpers")
struct FormatTests {
    @Test("nil date renders empty")
    func relativeResetNil() {
        #expect(Format.relativeReset(nil) == "")
    }

    @Test("past / now reads as resetting")
    func relativeResetPast() {
        #expect(Format.relativeReset(Date(timeIntervalSinceNow: -30)) == "resetting…")
    }

    @Test("sub-hour shows only minutes")
    func relativeResetMinutes() {
        // +5s buffer so the floor doesn't drop us to 29m mid-test.
        #expect(Format.relativeReset(Date(timeIntervalSinceNow: 30 * 60 + 5)) == "resets in 30m")
    }

    @Test("sub-day shows hours and minutes")
    func relativeResetHours() {
        let interval = 2 * 3600 + 30 * 60 + 5.0
        #expect(Format.relativeReset(Date(timeIntervalSinceNow: interval)) == "resets in 2h 30m")
    }

    @Test("multi-day shows days and hours")
    func relativeResetDays() {
        let interval = 2 * 86400 + 3 * 3600 + 5.0
        #expect(Format.relativeReset(Date(timeIntervalSinceNow: interval)) == "resets in 2d 3h")
    }

    @Test("countdown is measured from the injected now, not the wall clock")
    func resetDurationTracksInjectedNow() {
        // The fixed reset moment reads differently as `now` advances — the
        // property that lets a ticking view keep the countdown live instead of
        // frozen at its first draw.
        let reset = Date(timeIntervalSince1970: 1_789_830_220)  // 11:03:40
        #expect(
            Format.resetDuration(reset, now: reset.addingTimeInterval(-6 * 3600 - 18 * 60))
                == "6h 18m")
        #expect(
            Format.resetDuration(reset, now: reset.addingTimeInterval(-2 * 3600 - 31 * 60))
                == "2h 31m")
        #expect(Format.resetDuration(reset, now: reset.addingTimeInterval(30)) == "resetting…")
    }

    @Test("percent rounds to a whole number")
    func percentRounding() {
        #expect(Format.percent(4.0) == "4%")
        #expect(Format.percent(4.6) == "5%")
        #expect(Format.percent(0) == "0%")
    }

    @Test("updated-ago buckets: just now, minutes, hours, days")
    func updatedAgoBuckets() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func ago(_ seconds: TimeInterval) -> String {
            Format.updatedAgo(now.addingTimeInterval(-seconds), now: now)
        }
        #expect(ago(10) == "just now")
        #expect(ago(59) == "just now")
        #expect(ago(2 * 60) == "2m ago")
        #expect(ago(59 * 60) == "59m ago")
        #expect(ago(60 * 60) == "1h ago")  // whole hours drop the 0m
        #expect(ago(3600 + 5 * 60) == "1h 5m ago")
        #expect(ago(26 * 3600) == "1d ago")
    }

    // Locale-sensitive time formatting keeps these to prefix checks; the day
    // bucketing (today / tomorrow / weekday / date) is what's under test.
    @Test("absolute reset picks the nearest day description")
    func absoluteResetBuckets() {
        // A fixed reference away from midnight so +2h stays "today" and
        // +30h lands on "tomorrow" regardless of time zone drift: use noon.
        let cal = Calendar.current
        let noon = cal.date(
            bySettingHour: 12, minute: 0, second: 0, of: Date(timeIntervalSince1970: 1_700_000_000))!
        func reset(_ hours: Double) -> String {
            Format.absoluteReset(noon.addingTimeInterval(hours * 3600), now: noon)
        }
        // Calendar-day stepping (not hours*3600) so DST can't skew the buckets.
        func resetDays(_ days: Int) -> String {
            Format.absoluteReset(cal.date(byAdding: .day, value: days, to: noon)!, now: noon)
        }
        let weekdays = [
            "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday",
        ]
        #expect(reset(2).hasPrefix("Resets today at"))
        #expect(reset(26).hasPrefix("Resets tomorrow at"))
        #expect(reset(3 * 24).hasPrefix("Resets "))
        #expect(!reset(3 * 24).contains("today"))
        #expect(!reset(3 * 24).contains("tomorrow"))
        // Six days out a weekday is still unambiguous — use it…
        #expect(weekdays.contains { resetDays(6).contains($0) })
        // …but seven days out is the same weekday as today: explicit date.
        #expect(weekdays.allSatisfy { !resetDays(7).contains($0) })
        #expect(weekdays.allSatisfy { !resetDays(10).contains($0) })
    }
}
