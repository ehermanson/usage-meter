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

    @Test("distinct model pools are preserved when their windows match")
    func preservesDistinctPoolsWithIdenticalWindows() {
        let window: [String: Any] = ["usedPercent": 42.0, "windowDurationMins": 300]
        let root: [String: Any] = [
            "rateLimitsByLimitId": [
                "codex": ["primary": window],
                "gpt-5": ["primary": window, "limitName": "GPT-5"],
            ]
        ]
        let usage = CodexClient.parse(root)
        #expect(usage.pools.map(\.title) == [nil, "GPT-5"])
    }

    @Test("GPT-5.6 SOL family pools use their backend model names")
    func parsesSolFamilyPools() {
        // Newly provisioned pools can all start at the same utilization and reset.
        // They are still independent metered limits and must remain visible.
        let primary: [String: Any] = [
            "usedPercent": 0, "windowDurationMins": 300, "resetsAt": 1_783_600_000,
        ]
        let secondary: [String: Any] = [
            "usedPercent": 0, "windowDurationMins": 10_080, "resetsAt": 1_784_000_000,
        ]
        let root: [String: Any] = [
            "rateLimitsByLimitId": [
                "codex": ["primary": primary, "secondary": secondary],
                "gpt-5.6-sol": [
                    "limitId": "gpt-5.6-sol", "limitName": "GPT-5.6 Sol",
                    "primary": primary, "secondary": secondary,
                ],
                "gpt-5.6-terra": [
                    "limitId": "gpt-5.6-terra", "limitName": "GPT-5.6 Terra",
                    "primary": primary, "secondary": secondary,
                ],
                "gpt-5.6-luna": [
                    "limitId": "gpt-5.6-luna", "limitName": "GPT-5.6 Luna",
                    "primary": primary, "secondary": secondary,
                ],
            ]
        ]

        let usage = CodexClient.parse(root)

        #expect(usage.error == nil)
        #expect(usage.pools.count == 4)
        #expect(
            Set(usage.pools.compactMap(\.title))
                == Set(["GPT-5.6 Sol", "GPT-5.6 Terra", "GPT-5.6 Luna"]))
        #expect(usage.pools.allSatisfy { $0.windows.map(\.label) == ["5h", "Weekly"] })
    }

    @Test("empty result yields a failure")
    func emptyFails() {
        let usage = CodexClient.parse([:])
        #expect(usage.error != nil)
        #expect(!usage.hasWindows)
    }
}
