import Foundation
import Testing

@testable import UsageMeter

@Suite("Codex rate-limit parsing")
struct CodexParseTests {
    @Test("byId pool maps primary/secondary and derives window labels")
    func parsesByIdPool() {
        let epoch = 1_750_000_000.0
        let root: [String: Any] = [
            "rateLimitsByLimitId": [
                "codex": [
                    "primary": [
                        "usedPercent": 10.0, "windowDurationMins": 300, "resetsAt": epoch,
                    ],
                    "secondary": ["usedPercent": 20.0, "windowDurationMins": 10080],
                    "planType": "pro",
                ]
            ]
        ]
        let usage = CodexClient.parse(root)

        #expect(usage.error == nil)
        #expect(usage.plan == "Pro")
        #expect(usage.pools.count == 1)
        #expect(usage.pools[0].title == nil)  // the default "codex" pool has no subheader
        #expect(usage.allWindows.map(\.label) == ["5h", "Weekly"])  // 300 -> 5h, 10080 -> Weekly
        #expect(usage.allWindows[0].usedPercent == 10.0)
        #expect(usage.allWindows[0].resetAt == Date(timeIntervalSince1970: epoch))
    }

    @Test("snake_case keys and the default rateLimits fallback are supported")
    func parsesSnakeCaseFallback() {
        let root: [String: Any] = [
            "rate_limits": [
                "primary": ["used_percent": 5.0, "window_minutes": 60],
                "plan_type": "prolite",
            ]
        ]
        let usage = CodexClient.parse(root)
        // 60-minute window falls through labelFor's default hours branch.
        #expect(usage.allWindows.map(\.label) == ["1h"])
        #expect(usage.allWindows[0].usedPercent == 5.0)
    }

    @Test("pools with identical windows are de-duplicated")
    func dedupesIdenticalPools() {
        let window: [String: Any] = ["usedPercent": 42.0, "windowDurationMins": 300]
        let root: [String: Any] = [
            "rateLimitsByLimitId": [
                "codex": ["primary": window],
                "gpt-5": ["primary": window, "limitName": "GPT-5"],
            ]
        ]
        let usage = CodexClient.parse(root)
        #expect(usage.pools.count == 1)  // the mirror pool collapses into the first
    }

    @Test("empty result yields a failure")
    func emptyFails() {
        let usage = CodexClient.parse([:])
        #expect(usage.error != nil)
        #expect(!usage.hasWindows)
    }
}
