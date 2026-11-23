import Foundation
import Testing

@testable import UsageMeter

private final class StaticParser: ActivityLogParser {
    let provider: String
    private(set) var records: [UsageRecord] = []
    private let inner: ClaudeLogParser
    init(provider: String, sessionId: String) {
        self.provider = provider
        self.inner = ClaudeLogParser(fallbackSessionId: sessionId)
    }
    func consume(_ line: Data, decoder: JSONDecoder) {
        let before = inner.records.count
        inner.consume(line, decoder: decoder)
        for rec in inner.records.dropFirst(before) {
            records.append(
                UsageRecord(
                    provider: provider, timestamp: rec.timestamp, model: rec.model,
                    sessionId: rec.sessionId, dedupeKey: rec.dedupeKey, tokens: rec.tokens))
        }
    }
}

private struct StaticSource: ActivityLogSource {
    let name: String
    let root: URL
    let markers = ["\"usage\""]
    func logFiles() -> [URL] { ActivitySources.jsonlFiles(under: [root]) }
    func makeParser(for file: URL) -> ActivityLogParser {
        StaticParser(provider: name, sessionId: ClaudeLogSource.sessionId(forFile: file))
    }
}

@Suite("Disabled providers")
struct DisabledProvidersTests {
    @MainActor
    private func makeStore(
        providers: [ProviderUsage],
        disabled: Set<String> = [],
        pinned: String? = nil
    ) -> (store: UsageStore, defaults: UserDefaults, domain: String) {
        let domain = "DisabledProvidersTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        if !disabled.isEmpty {
            defaults.set(disabled.sorted(), forKey: UsageStore.disabledProvidersKey)
        }
        if let pinned {
            defaults.set(pinned, forKey: "pinnedProvider")
        }
        let store = UsageStore(defaults: defaults, publishSideEffects: false)
        store.providers = providers
        store.menuBarStyle = .full
        return (store, defaults, domain)
    }

    private func sample(_ name: String, fiveHour: Double = 20) -> ProviderUsage {
        .ok(
            name,
            pools: [
                UsagePool(
                    title: nil,
                    windows: [
                        UsageWindow(label: "5h", usedPercent: fiveHour, resetAt: nil),
                        UsageWindow(label: "Weekly", usedPercent: 40, resetAt: nil),
                    ])
            ])
    }

    @MainActor
    @Test("loadDisabledProviders keeps only known providers and cleans unknown entries")
    func loadFiltersUnknown() {
        let domain = "DisabledProvidersTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }

        defaults.set(["Codex", "Obsolete"], forKey: UsageStore.disabledProvidersKey)
        let loaded = UsageStore.loadDisabledProviders(defaults: defaults)
        #expect(loaded == ["Codex"])
        #expect(defaults.stringArray(forKey: UsageStore.disabledProvidersKey) == ["Codex"])
    }

    @MainActor
    @Test("disabling a provider hides it everywhere, clears its pin, and keeps it re-enableable")
    func disableUpdatesVisibleMenuBarAndSettings() {
        let initial = [sample("Claude", fiveHour: 15), sample("Codex", fiveHour: 80)]
        let (store, defaults, domain) = makeStore(providers: initial, pinned: "Codex")
        defer { defaults.removePersistentDomain(forName: domain) }

        #expect(store.visibleProviders.map(\.name) == ["Claude", "Codex"])
        #expect(store.providersSummaryLabel == "All")

        store.setProviderEnabled("Codex", false)

        #expect(!store.isProviderEnabled("Codex"))
        #expect(store.visibleProviders.map(\.name) == ["Claude"])
        #expect(store.selectableProviders == ["Claude"])
        // Clearing the pin stops the picker showing a disabled provider.
        #expect(store.pinnedProvider == nil)
        #expect(defaults.stringArray(forKey: UsageStore.disabledProvidersKey) == ["Codex"])
        // Codex stays listed in manageableProviders so the user can turn it back on.
        #expect(store.manageableProviders == ["Claude", "Codex"])
        #expect(store.providersSummaryLabel == "1 of 2")
        // Menu bar falls back to the remaining enabled provider.
        #expect(store.menuBarDisplay.glyphs.map(\.id) == ["Claude"])

        // Re-enabling removes it from disabledProviders and persists the change.
        store.setProviderEnabled("Codex", true)
        #expect(store.isProviderEnabled("Codex"))
        #expect(defaults.stringArray(forKey: UsageStore.disabledProvidersKey) == [])

        // Disabling every provider leaves `providers` non-empty (so the UI shows
        // the "all turned off" note instead of "Loading…").
        store.setProviderEnabled("Codex", false)
        store.setProviderEnabled("Claude", false)
        #expect(!store.providers.isEmpty)
        #expect(store.visibleProviders.isEmpty)
        #expect(store.providersSummaryLabel == "None")
    }

    @Test(
        "ActivityScanner skips excluded providers, drops their records, and rescans when re-enabled"
    )
    func scannerExcludesAndReincludesProviders() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "disabled-scan-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }

        let claudeDir = root.appendingPathComponent("claude")
        let otherDir = root.appendingPathComponent("codex")
        try fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: otherDir, withIntermediateDirectories: true)

        let line1 = claudeLine(id: "m1", request: "r1", output: 10) + "\n"
        let line2 = claudeLine(id: "m2", request: "r2", output: 20) + "\n"
        try Data(line1.utf8).write(to: claudeDir.appendingPathComponent("a.jsonl"))
        try Data(line2.utf8).write(to: otherDir.appendingPathComponent("b.jsonl"))

        let scanner = ActivityScanner(sources: [
            StaticSource(name: "Claude", root: claudeDir),
            StaticSource(name: "Codex", root: otherDir),
        ])

        let both = await scanner.scan()
        #expect(both.detectedProviders == ["Claude", "Codex"])
        #expect(both.records.count == 2)

        // Excluding Codex drops its tracked file and records without reading it.
        let withoutCodex = await scanner.scan(excludedProviders: ["Codex"])
        #expect(withoutCodex.detectedProviders == ["Claude"])
        #expect(withoutCodex.records.count == 1)
        #expect(withoutCodex.stats.filesRead == 0)
        #expect(withoutCodex.generation > both.generation)

        // Re-enabling Codex rescans its file cleanly.
        let restored = await scanner.scan(excludedProviders: [])
        #expect(restored.detectedProviders == ["Claude", "Codex"])
        #expect(restored.records.count == 2)
        #expect(restored.stats.filesRead == 1)
    }

    @MainActor
    @Test("ActivityStore immediately drops a disabled provider from its summary")
    func activityStoreHidesDisabledProviderImmediately() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "disabled-store-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }

        let claudeDir = root.appendingPathComponent("claude")
        let codexDir = root.appendingPathComponent("codex")
        try fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: codexDir, withIntermediateDirectories: true)

        let nowISO = Parse.isoString(.now)
        try Data((claudeLine(id: "m1", request: "r1", timestamp: nowISO, output: 100) + "\n").utf8)
            .write(to: claudeDir.appendingPathComponent("a.jsonl"))
        try Data((claudeLine(id: "m2", request: "r2", timestamp: nowISO, output: 200) + "\n").utf8)
            .write(to: codexDir.appendingPathComponent("b.jsonl"))

        let scanner = ActivityScanner(sources: [
            StaticSource(name: "Claude", root: claudeDir),
            StaticSource(name: "Codex", root: codexDir),
        ])
        let store = ActivityStore(
            scanner: scanner,
            priceCache: root.appendingPathComponent("missing-prices.json"),
            disabledProviders: [])
        store.range = .week
        await store.refresh(force: true)

        #expect(store.summary?.providers.map(\.name) == ["Claude", "Codex"])
        #expect(store.summary?.totalTokens == 304)

        store.setDisabledProviders(["Codex"])
        #expect(store.summary?.providers.map(\.name) == ["Claude"])
        #expect(store.summary?.totalTokens == 102)
    }
}
