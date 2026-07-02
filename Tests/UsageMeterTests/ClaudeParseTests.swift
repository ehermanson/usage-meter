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

    @Test("unknown codename windows are ignored, not shown as bogus rows")
    func ignoresUnknownWindows() {
        // Internal codenames (amber_ladder, tangelo, …) become window-shaped when
        // active but aren't real user limits — only the allowlist should render.
        let limits: [String: Any] = [
            "five_hour": ["utilization": 4.0, "resets_at": "2026-06-18T20:00:00Z"],
            "amber_ladder": ["utilization": 0.0, "resets_at": "2026-09-02T06:59:59+00:00"],
            "tangelo": ["utilization": 12.0, "resets_at": "2026-06-18T20:00:00Z"],
        ]
        let usage = ClaudeClient.parse(limits, plan: nil)
        #expect(usage.allWindows.map(\.label) == ["5h"])
    }

    @Test("per-model weekly windows (model_scoped) surface as Weekly · <model>")
    func parsesModelScopedWindows() {
        // Per-model limits (e.g. Fable) arrive in a `model_scoped` array, separate
        // from the null top-level seven_day_<model> keys.
        let limits: [String: Any] = [
            "five_hour": ["utilization": 29.0, "resets_at": "2026-07-02T17:50:00Z"],
            "seven_day": ["utilization": 6.0, "resets_at": "2026-07-06T10:00:00Z"],
            "seven_day_opus": NSNull(),
            "seven_day_sonnet": NSNull(),
            "model_scoped": [
                [
                    "display_name": "Fable", "utilization": 10.0,
                    "resets_at": "2026-07-06T10:00:00Z",
                ]
            ],
        ]
        let usage = ClaudeClient.parse(limits, plan: "Max")
        #expect(usage.error == nil)
        #expect(usage.allWindows.map(\.label) == ["5h", "Weekly · all", "Weekly · Fable"])
        let fable = usage.allWindows.first { $0.label == "Weekly · Fable" }
        #expect(fable?.usedPercent == 10.0)
        #expect(fable?.resetAt != nil)
    }

    @Test("model_scoped does not duplicate a known seven_day_<model> window")
    func modelScopedDoesNotDuplicate() {
        // If both a top-level seven_day_opus and a model_scoped "Opus" are present,
        // only one "Weekly · Opus" row should render.
        let limits: [String: Any] = [
            "seven_day_opus": ["utilization": 20.0, "resets_at": "2026-07-06T10:00:00Z"],
            "model_scoped": [
                [
                    "display_name": "Opus", "utilization": 20.0,
                    "resets_at": "2026-07-06T10:00:00Z",
                ]
            ],
        ]
        let usage = ClaudeClient.parse(limits, plan: "Max")
        #expect(usage.allWindows.map(\.label) == ["Weekly · Opus"])
    }

    @Test("no window-shaped entries yields a retryable failure")
    func noWindowsFails() {
        let usage = ClaudeClient.parse(["limits": ["foo": 1]], plan: "Pro")
        #expect(usage.error != nil)
        #expect(usage.retryable)
        #expect(usage.plan == "Pro")
        #expect(!usage.hasWindows)
    }

    @Test("enterprise dollar-budget usage surfaces as a Usage window with amounts")
    func parsesEnterpriseSpend() {
        // Enterprise reports all time windows null; the real signal is a monthly
        // dollar spend against a limit under `spend` (no resets_at).
        let limits: [String: Any] = [
            "five_hour": NSNull(),
            "seven_day": NSNull(),
            "spend": [
                "used": ["amount_minor": 23731, "currency": "USD", "exponent": 2],
                "limit": ["amount_minor": 30000, "currency": "USD", "exponent": 2],
                "percent": 79,
                "severity": "warning",
                "enabled": true,
            ],
            "limits": [],
        ]
        let usage = ClaudeClient.parse(limits, plan: "Enterprise")
        #expect(usage.error == nil)
        let windows = usage.allWindows
        #expect(windows.map(\.label) == ["Usage"])
        #expect(windows.first?.usedPercent == 79)
        #expect(windows.first?.resetAt == nil)
        #expect(windows.first?.detail == "$237 / $300")
    }

    @Test("disabled spend is ignored")
    func ignoresDisabledSpend() {
        let limits: [String: Any] = [
            "spend": ["percent": 0, "enabled": false, "limit": NSNull()]
        ]
        let usage = ClaudeClient.parse(limits, plan: "Max")
        #expect(!usage.hasWindows)
        #expect(usage.error != nil)
    }
}
