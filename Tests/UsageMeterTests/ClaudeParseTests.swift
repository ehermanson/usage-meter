import Foundation
import Testing

@testable import UsageMeter

@Suite("Claude rate-limit parsing")
struct ClaudeParseTests {
    @Test("known windows are labelled and ordered, junk keys skipped")
    func parsesKnownWindows() {
        let limits: [String: Any] = [
            "seven_day": ["utilization": 31.0, "resets_at": "2026-06-20T00:00:00.000Z"],
            "five_hour": ["utilization": 4.2, "resets_at": "2026-06-18T20:00:00Z"],
            // Not window-shaped (no utilization / resets_at) — must be ignored.
            "extra_usage": ["spend": 12],
        ]
        let usage = ClaudeClient.parse(limits, plan: "Max")

        #expect(usage.error == nil)
        #expect(usage.plan == "Max")
        let windows = usage.allWindows
        // knownLabels order puts five_hour before seven_day.
        #expect(windows.map(\.label) == ["5h", "Weekly · all"])
        #expect(windows[0].usedPercent == 4.2)
        // Both date shapes (plain + fractional seconds) resolve.
        #expect(windows[0].resetAt != nil)
        #expect(windows[1].resetAt != nil)
    }

    @Test("unknown but window-shaped keys get a prettified label")
    func parsesUnknownWindow() {
        let limits: [String: Any] = [
            "custom_thing": ["utilization": 7.0, "resets_at": "2026-06-18T20:00:00Z"]
        ]
        let usage = ClaudeClient.parse(limits, plan: nil)
        #expect(usage.allWindows.map(\.label) == ["Custom Thing"])
    }

    @Test("no window-shaped entries yields a retryable failure")
    func noWindowsFails() {
        let usage = ClaudeClient.parse(["limits": ["foo": 1]], plan: "Pro")
        #expect(usage.error != nil)
        #expect(usage.retryable)
        #expect(usage.plan == "Pro")
        #expect(!usage.hasWindows)
    }
}
