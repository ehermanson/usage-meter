import Foundation
import SwiftUI
import Testing

@testable import UsageMeter

/// The backstop that keeps one wedged provider from taking the whole refresh
/// with it. A fetch really can block forever — reading a sign-in tool's Keychain
/// item raises an authorization prompt, and `SecItemCopyMatching` waits on it
/// indefinitely — and before this existed a single one of those froze every
/// provider's data and the "Updated" timestamp along with it.
@Suite("Provider fetch timeout")
struct FetchTimeoutTests {
    /// Never returns within the life of a test.
    private struct HangingProvider: UsageProvider {
        let name = "Hang"
        let accent = Color.gray
        var fetchTimeout: TimeInterval = 0.3
        func fetch() async -> ProviderUsage {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            return .ok("Hang", pools: [])
        }
    }

    private struct QuickProvider: UsageProvider {
        let name = "Quick"
        let accent = Color.gray
        var fetchTimeout: TimeInterval = 10
        func fetch() async -> ProviderUsage {
            .ok(
                "Quick",
                pools: [
                    UsagePool(
                        title: nil,
                        windows: [UsageWindow(label: "5h", usedPercent: 12, resetAt: nil)])
                ])
        }
    }

    @Test("a fetch that never returns gives up instead of blocking the pass")
    func hangingFetchTimesOut() async {
        let started = Date()
        let result = await UsageStore.fetch(HangingProvider())
        let elapsed = Date().timeIntervalSince(started)

        #expect(result.error == "not responding")
        // Retryable, so the row keeps its last good numbers rather than blanking.
        #expect(result.retryable)
        #expect(result.allWindows.isEmpty)
        // Generous, but far below the 60s the provider would otherwise take —
        // the point is that it returns at all.
        #expect(elapsed < 10)
    }

    @Test("a fetch that finishes in time is passed straight through")
    func fastFetchIsUntouched() async {
        let result = await UsageStore.fetch(QuickProvider())
        #expect(result.error == nil)
        #expect(result.fiveHour?.usedPercent == 12)
    }

    @Test("one hung provider doesn't delay a healthy one")
    func providersAreIndependent() async {
        // The store fetches concurrently, so a wedged provider must not add its
        // timeout to anyone else's latency.
        async let slow = UsageStore.fetch(HangingProvider())
        async let quick = UsageStore.fetch(QuickProvider())
        let started = Date()
        let (slowResult, quickResult) = await (slow, quick)
        #expect(slowResult.error == "not responding")
        #expect(quickResult.error == nil)
        #expect(Date().timeIntervalSince(started) < 10)
    }
}
