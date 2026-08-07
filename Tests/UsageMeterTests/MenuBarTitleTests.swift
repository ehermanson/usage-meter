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
        withStore(providers: [Self.split()]) { store in
            #expect(store.menuBarTitle == "5h 7% · Wk 31%")
        }
    }

    /// A conventional 5h + weekly snapshot.
    private static func split(_ five: Double = 7, _ week: Double = 31) -> ProviderUsage {
        .ok(
            "Claude",
            pools: [
                UsagePool(
                    title: nil,
                    windows: [
                        UsageWindow(label: "5h", usedPercent: five, resetAt: nil),
                        UsageWindow(label: "Weekly", usedPercent: week, resetAt: nil),
                    ])
            ])
    }

    // MARK: - Render model

    @MainActor
    @Test("the ring tracks 5hr usage, and the mark replaces the provider name")
    func displaySplit() {
        withStore(providers: [Self.split(42, 31)]) { store in
            let display = store.menuBarDisplay
            #expect(display.fraction == 0.42)
            #expect(display.severity == 0.42)
            #expect(display.logoResource == "claude-logo")
            // No name segment: the mark in the ring already identifies Claude.
            #expect(
                display.segments == [
                    MenuBarSegment(text: "5h", style: .label),
                    MenuBarSegment(text: "42%", style: .primary),
                    MenuBarSegment(text: "Wk", style: .label),
                    MenuBarSegment(text: "31%", style: .secondary),
                ])
        }
    }

    @MainActor
    @Test("remaining mode drains the ring but keeps its color on usage")
    func displayRemainingDrainsRing() {
        withStore(providers: [Self.split(80, 31)], showRemaining: true) { store in
            let display = store.menuBarDisplay
            // The arc follows the number down, battery-style, matching the
            // dropdown's bars — but the color still keys off the 80% consumed,
            // so a nearly-drained ring reads red rather than cooling off.
            #expect(abs(display.fraction - 0.2) < 0.0001)
            #expect(display.severity == 0.8)
            #expect(display.segments.contains(MenuBarSegment(text: "20%", style: .primary)))
        }
    }

    @MainActor
    @Test("the default mode fills the ring, with arc and color agreeing")
    func displayDefaultFillsRing() {
        withStore(providers: [Self.split(80, 31)]) { store in
            let display = store.menuBarDisplay
            #expect(display.fraction == 0.8)
            #expect(display.severity == 0.8)
        }
    }

    @MainActor
    @Test("the fixed-budget window keeps its direction marked")
    func displayFixedBudget() {
        withStore(providers: [Self.enterprise(6)], showRemaining: true) { store in
            #expect(
                store.menuBarDisplay.segments == [
                    MenuBarSegment(text: "Usage", style: .label),
                    MenuBarSegment(text: "94%", style: .primary),
                    MenuBarSegment(text: "left", style: .label),
                ])
        }
    }

    @MainActor
    @Test("compact mode drops the weekly pair from the segments")
    func displayCompactDropsWeekly() {
        withStore(providers: [Self.split(42, 31)]) { store in
            store.compactMenuBar = true
            let display = store.menuBarDisplay
            #expect(
                display.segments == [
                    MenuBarSegment(text: "5h", style: .label),
                    MenuBarSegment(text: "42%", style: .primary),
                ])
            // The ring is unaffected — it only ever tracked the 5hr window.
            #expect(display.fraction == 0.42)
        }
    }

    @MainActor
    @Test("no usable provider falls back to a placeholder and an empty ring")
    func displayEmpty() {
        withStore(providers: []) { store in
            let display = store.menuBarDisplay
            #expect(display.fraction == 0)
            #expect(display.logoResource == nil)
            #expect(display.segments == [MenuBarSegment(text: "—", style: .label)])
        }
    }

    /// A provider the registry doesn't know, so `style(for:)` finds no mark.
    private static func unbranded(_ percent: Double) -> ProviderUsage {
        .ok(
            "Mystery",
            pools: [
                UsagePool(
                    title: nil,
                    windows: [UsageWindow(label: "5h", usedPercent: percent, resetAt: nil)])
            ])
    }

    @MainActor
    @Test("an unbranded provider spells out its name only when one is needed")
    func displayNoLogoNamesOnlyWhenAmbiguous() {
        // Solo: nothing to disambiguate, so the name stays off — same rule the
        // flat title uses.
        withStore(providers: [Self.unbranded(60)]) { store in
            #expect(store.menuBarDisplay.logoResource == nil)
            #expect(
                store.menuBarDisplay.segments.first == MenuBarSegment(text: "5h", style: .label))
        }
        // Alongside another provider, with no mark to identify it, the name has
        // to carry that job.
        withStore(providers: [Self.unbranded(60), Self.split()]) { store in
            store.pinnedProvider = "Mystery"
            #expect(
                store.menuBarDisplay.segments.first
                    == MenuBarSegment(text: "Mystery", style: .label))
        }
    }

    @MainActor
    @Test("a marked provider drops its name even against other providers")
    func displayLogoReplacesNameWhenAmbiguous() {
        withStore(providers: [Self.split(42), Self.unbranded(60)]) { store in
            store.pinnedProvider = "Claude"
            let display = store.menuBarDisplay
            #expect(display.logoResource == "claude-logo")
            #expect(display.segments.first == MenuBarSegment(text: "5h", style: .label))
        }
    }
}
