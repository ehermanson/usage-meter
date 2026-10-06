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
        // No reset in the payload; one is inferred from the calendar month.
        #expect(windows.first?.resetAt != nil)
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

    @Test("the helper's config dir is kept for the log scan; null clears it, absent keeps it")
    func remembersConfigDir() throws {
        let suite = "ClaudeParseTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = ClaudeClient.detectedConfigDirKey
        #expect(key != "claudeConfigDir")  // never the user's own pick

        ClaudeClient.rememberConfigDir(
            from: ["ok": true, "config_dir": "/Users/me/.claude-work"], defaults: defaults)
        #expect(defaults.string(forKey: key) == "/Users/me/.claude-work")

        // An older helper, or one that failed before resolving: unchanged.
        ClaudeClient.rememberConfigDir(from: ["ok": false, "code": "timeout"], defaults: defaults)
        #expect(defaults.string(forKey: key) == "/Users/me/.claude-work")

        // A leading tilde is expanded, as the log scan would.
        ClaudeClient.rememberConfigDir(from: ["config_dir": "~/.claude-alt"], defaults: defaults)
        #expect(defaults.string(forKey: key) == NSHomeDirectory() + "/.claude-alt")

        // Resolved to nothing (Claude Code's default): forgotten.
        let json = #"{"ok":false,"code":"not_signed_in","config_dir":null}"#
        let root = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        ClaudeClient.rememberConfigDir(from: root, defaults: defaults)
        #expect(defaults.string(forKey: key) == nil)
    }

    @Test("window lengths come from the key: 5h, 7d for weekly and model-scoped, none otherwise")
    func parsesDurations() {
        let limits: [String: Any] = [
            "five_hour": ["utilization": 10.0, "resets_at": "2026-06-18T20:00:00Z"],
            "seven_day": ["utilization": 20.0, "resets_at": "2026-06-20T00:00:00Z"],
            "seven_day_sonnet": ["utilization": 30.0, "resets_at": "2026-06-20T00:00:00Z"],
            "overage": ["utilization": 5.0, "resets_at": "2026-06-20T00:00:00Z"],
            "model_scoped": [
                ["display_name": "Fable", "utilization": 40.0, "resets_at": "2026-06-20T00:00:00Z"]
            ],
            "spend": ["percent": 12.0, "enabled": true],
        ]
        let windows = ClaudeClient.parse(limits, plan: nil).allWindows
        let byLabel = Dictionary(uniqueKeysWithValues: windows.map { ($0.label, $0.duration) })
        #expect(byLabel["5h"] == .some(5 * 3600))
        #expect(byLabel["Weekly · all"] == .some(7 * 24 * 3600))
        #expect(byLabel["Weekly · Sonnet"] == .some(7 * 24 * 3600))
        #expect(byLabel["Weekly · Fable"] == .some(7 * 24 * 3600))
        // Overage isn't a fixed span of time; the dollar budget is a month.
        #expect(byLabel["Overage"] == .some(nil))
        #expect(byLabel["Usage"] != .some(nil))
    }

    /// A UTC instant from components, for pinning `now` in spend-month tests.
    private func utc(
        _ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, _ sec: Int = 0
    )
        -> Date
    {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(
            from: DateComponents(year: y, month: m, day: d, hour: h, minute: min, second: sec))!
    }

    /// The parsed spend window at `now`.
    private func spend(percent: Double = 40, now: Date) -> UsageWindow? {
        let limits: [String: Any] = ["spend": ["percent": percent, "enabled": true]]
        return ClaudeClient.parse(limits, plan: nil, now: now).allWindows.first
    }

    private let day: TimeInterval = 24 * 3600

    @Test(
        "spend resets at 00:00 UTC on the first of next month and spans this month",
        arguments: [
            // mid-month, 31-day month
            (2026, 7, 15, 12, 59, 59, 2026, 8, 31.0),
            // 28-day February
            (2026, 2, 10, 0, 0, 0, 2026, 3, 28.0),
            // leap February
            (2028, 2, 10, 0, 0, 0, 2028, 3, 29.0),
            // December rolls into January
            (2026, 12, 20, 0, 0, 0, 2027, 1, 31.0),
            // the last second of a 30-day month still belongs to it
            (2026, 9, 30, 23, 59, 59, 2026, 10, 30.0),
        ])
    func spendMonth(
        y: Int, m: Int, d: Int, h: Int, min: Int, sec: Int,
        resetY: Int, resetM: Int, days: Double
    ) throws {
        let w = try #require(spend(now: utc(y, m, d, h, min, sec)))
        #expect(w.resetAt == utc(resetY, resetM, 1))
        #expect(w.duration == days * day)
    }

    @Test("the month is the UTC one, even where the local date is already the next")
    func spendMonthIsUTC() throws {
        // 23:30 UTC on Jan 31 is already Feb 1 in Tokyo; the budget is still January's.
        let now = utc(2026, 1, 31, 23, 30)
        let w = try #require(spend(now: now))
        #expect(w.resetAt == utc(2026, 2, 1))
        #expect(w.duration == 31 * day)
    }

    @Test("a parsed spend window gets a pace: 79% on the 10th of a 30-day month is ahead")
    func spendPace() throws {
        let now = utc(2026, 9, 10)
        let w = try #require(spend(percent: 79, now: now))
        let pace = try #require(UsagePace(window: w, now: now))
        #expect(pace.status == .aheadOfPace)
    }
}
