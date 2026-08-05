import Foundation
import Testing

@testable import UsageMeter

/// The status-item string for the odd plan shapes — most importantly the
/// fixed-budget Enterprise plan whose single "Usage" window used to render as a
/// bare "Usage 6%" with nothing saying whose usage or which direction.
@Suite("Menu bar title")
struct MenuBarTitleTests {
    /// Runs `check` against the shared store with the given state swapped in,
    /// restoring whatever was there before (the store is a singleton).
    @MainActor
    private func withStore(
        providers: [ProviderUsage], showRemaining: Bool = false,
        _ check: (UsageStore) -> Void
    ) {
        let store = UsageStore.shared
        let saved = (
            store.providers, store.pinnedProvider, store.showRemaining, store.compactMenuBar
        )
        defer {
            store.providers = saved.0
            store.pinnedProvider = saved.1
            store.showRemaining = saved.2
            store.compactMenuBar = saved.3
        }
        store.providers = providers
        store.pinnedProvider = nil
        store.showRemaining = showRemaining
        store.compactMenuBar = false
        check(store)
    }

    /// A $-capped Enterprise snapshot: one generic "Usage" window, no reset.
    private static func enterprise(_ percent: Double) -> ProviderUsage {
        .ok(
            "Claude",
            pools: [
                UsagePool(
                    title: nil,
                    windows: [
                        UsageWindow(
                            label: "Usage", usedPercent: percent, resetAt: nil,
                            detail: "$237 / $1,000")
                    ])
            ], plan: "Enterprise")
    }

    @MainActor
    @Test("fixed-budget Usage window names the provider even when solo")
    func enterpriseSolo() {
        withStore(providers: [Self.enterprise(6)]) { store in
            #expect(store.menuBarTitle == "Claude Usage 6%")
        }
    }

    @MainActor
    @Test("remaining mode marks the direction on the fixed-budget title")
    func enterpriseRemaining() {
        withStore(providers: [Self.enterprise(6)], showRemaining: true) { store in
            #expect(store.menuBarTitle == "Claude Usage 94% left")
        }
    }

    @MainActor
    @Test("5h/weekly split keeps the compact solo title, no name")
    func splitSolo() {
        let claude = ProviderUsage.ok(
            "Claude",
            pools: [
                UsagePool(
                    title: nil,
                    windows: [
                        UsageWindow(label: "5h", usedPercent: 7, resetAt: nil),
                        UsageWindow(label: "Weekly", usedPercent: 31, resetAt: nil),
                    ])
            ])
        withStore(providers: [claude]) { store in
            #expect(store.menuBarTitle == "5h 7% · Wk 31%")
        }
    }
}
