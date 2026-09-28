import Foundation
import Testing

@testable import UsageMeter

/// Which providers the Tokens and Cost charts draw, on summaries built the
/// way the app builds them.
@Suite("Activity chart")
struct ActivityChartTests {
    private static let now = Parse.isoDate("2026-09-27T18:00:00Z")!

    /// $1 per token for "priced"; every other model has no price.
    private static let pricing = PricingTable(models: [
        "priced": ModelPricing(base: .init(input: 1, output: 1))
    ])

    private static func record(_ provider: String, model: String) -> UsageRecord {
        UsageRecord(
            provider: provider, timestamp: now.addingTimeInterval(-3600), model: model,
            sessionId: "\(provider)-session", dedupeKey: nil, tokens: TokenCounts(input: 100))
    }

    private static func summary(_ records: [UsageRecord]) -> ActivitySummary {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return ActivityAggregator.summarize(
            records: records, range: .week, now: now, calendar: calendar, pricing: pricing,
            providers: ["Claude", "Codex"], detected: ["Claude", "Codex"])
    }

    @Test("Cost charts only providers with a cost; Tokens charts every active one")
    func unpricedProviderLeavesCostChart() {
        let s = Self.summary([
            Self.record("Claude", model: "priced"), Self.record("Codex", model: "unknown"),
        ])
        #expect(ActivityMetric.tokens.chartedProviders(s).map(\.name) == ["Claude", "Codex"])
        #expect(ActivityMetric.cost.chartedProviders(s).map(\.name) == ["Claude"])
        #expect(ActivityMetric.cost.emptyChartNote(s) == nil)
        // The providers card still splits the range between both.
        #expect(s.activeProviders.map(\.name) == ["Claude", "Codex"])
    }

    @Test("the providers card's keys match the lines: hollow for one the chart leaves out")
    func cardKeysMatchChart() {
        let s = Self.summary([
            Self.record("Claude", model: "priced"), Self.record("Codex", model: "unknown"),
        ])
        let (claude, codex) = (s.activeProviders[0], s.activeProviders[1])
        #expect(ActivityMetric.cost.key(for: claude, in: s) == .charted)
        #expect(ActivityMetric.cost.key(for: codex, in: s) == .uncharted)
        #expect(ActivityMetric.tokens.key(for: claude, in: s) == .charted)
        #expect(ActivityMetric.tokens.key(for: codex, in: s) == .charted)
    }

    @Test("an idle provider is on neither chart")
    func idleProviderCharted() {
        let s = Self.summary([Self.record("Claude", model: "priced")])
        #expect(s.providers.map(\.name) == ["Claude", "Codex"])
        #expect(ActivityMetric.tokens.chartedProviders(s).map(\.name) == ["Claude"])
        #expect(ActivityMetric.cost.chartedProviders(s).map(\.name) == ["Claude"])
    }

    @Test("with nothing priced, the note stands in for what would be an empty Cost chart")
    func nothingPriced() {
        let s = Self.summary([
            Self.record("Claude", model: "unknown"), Self.record("Codex", model: "unknown"),
        ])
        #expect(ActivityMetric.cost.chartedProviders(s).isEmpty)
        #expect(ActivityMetric.cost.emptyChartNote(s) == "No priced activity in this range")
        #expect(ActivityMetric.tokens.chartedProviders(s).count == 2)
        #expect(ActivityMetric.tokens.emptyChartNote(s) == nil)
    }
}
