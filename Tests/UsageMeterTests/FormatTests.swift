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

    @Test("percent rounds to a whole number")
    func percentRounding() {
        #expect(Format.percent(4.0) == "4%")
        #expect(Format.percent(4.6) == "5%")
        #expect(Format.percent(0) == "0%")
    }
}
