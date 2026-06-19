import Foundation
import Testing

@testable import UsageMeter

@Suite("Usage models")
struct ModelTests {
    @Test("clampedFraction clamps to 0...1")
    func clampedFraction() {
        #expect(UsageWindow(label: "5h", usedPercent: -10, resetAt: nil).clampedFraction == 0)
        #expect(UsageWindow(label: "5h", usedPercent: 50, resetAt: nil).clampedFraction == 0.5)
        #expect(UsageWindow(label: "5h", usedPercent: 150, resetAt: nil).clampedFraction == 1)
    }

    @Test("identity is derived from the label")
    func windowIdentity() {
        #expect(UsageWindow(label: "Weekly", usedPercent: 1, resetAt: nil).id == "Weekly")
    }

    private func provider(labels: [String]) -> ProviderUsage {
        let windows = labels.map { UsageWindow(label: $0, usedPercent: 1, resetAt: nil) }
        return .ok("Claude", pools: [UsagePool(title: nil, windows: windows)])
    }

    @Test("fiveHour prefers a 5h-labelled window")
    func fiveHourPrefersMatch() {
        #expect(provider(labels: ["Weekly · all", "5h"]).fiveHour?.label == "5h")
    }

    @Test("fiveHour falls back to the first window")
    func fiveHourFallback() {
        #expect(provider(labels: ["Daily", "Monthly"]).fiveHour?.label == "Daily")
    }

    @Test("weekly matches week or 7d labels")
    func weeklyMatching() {
        #expect(provider(labels: ["5h", "Weekly · all"]).weekly?.label == "Weekly · all")
        #expect(provider(labels: ["5h", "7d · Sonnet"]).weekly?.label == "7d · Sonnet")
        #expect(provider(labels: ["5h", "Daily"]).weekly == nil)
    }

    @Test("allWindows flattens every pool")
    func allWindowsFlattens() {
        let usage = ProviderUsage.ok(
            "Codex",
            pools: [
                UsagePool(
                    title: nil, windows: [UsageWindow(label: "5h", usedPercent: 1, resetAt: nil)]),
                UsagePool(
                    title: "gpt",
                    windows: [UsageWindow(label: "Weekly", usedPercent: 2, resetAt: nil)]),
            ])
        #expect(usage.allWindows.count == 2)
        #expect(usage.hasWindows)
    }

    @Test("ok and failed factories set the expected fields")
    func factories() {
        let ok = ProviderUsage.ok("Claude", pools: [], plan: "Max")
        #expect(ok.error == nil)
        #expect(ok.plan == "Max")
        #expect(!ok.hasWindows)

        let failed = ProviderUsage.failed("Claude", "throttled", retryable: true, plan: "Pro")
        #expect(failed.error == "throttled")
        #expect(failed.retryable)
        #expect(failed.plan == "Pro")
    }
}
