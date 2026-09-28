import Foundation
import Testing

@testable import UsageMeter

@Suite("Activity formatting")
struct ActivityFormatTests {
    @Test("token counts: exact below 1K, always three significant digits above")
    func tokens() {
        let cases: [(Int, String)] = [
            (0, "0"), (950, "950"), (999, "999"), (1000, "1K"), (1500, "1.50K"),
            (10_000, "10K"), (12_345, "12.3K"), (99_960, "100K"), (9_996, "10K"),
            (145_000_000, "145M"), (14_500_000, "14.5M"), (1_500_000, "1.50M"),
            (999_950, "1M"), (100_000_000, "100M"), (2_000_000_000, "2B"),
            (2_896_000_000, "2.90B"), (2_770_000_000, "2.77B"), (2_855_807_620, "2.86B"),
            (1_000_000_000_000, "1T"), (-12_345, "-12.3K"), (-1_500_000, "-1.50M"),
            // A fraction goes only when all of it is zero.
            (1_010_000, "1.01M"), (1_100_000, "1.10M"), (10_100, "10.1K"),
        ]
        for (value, expected) in cases {
            #expect(Format.tokens(value) == expected, "\(value)")
        }
    }

    @Test("cost: dollars and cents, laid out for the locale")
    func cost() {
        let us = Locale(identifier: "en_US")
        #expect(Format.cost(1257.9, locale: us) == "$1,257.90")
        #expect(Format.cost(0, locale: us) == "$0.00")
        #expect(Format.cost(0.004, locale: us) == "$0.00")
        #expect(Format.cost(156.785, locale: us).hasPrefix("$156.7"))
        let german = Format.cost(1257.9, locale: Locale(identifier: "de_DE"))
        #expect(german.contains("1.257,90"))
    }

    @Test("axis labels stay compact")
    func axes() {
        #expect(Format.tokensAxis(0) == "0")
        #expect(Format.tokensAxis(500) == "500")
        #expect(Format.tokensAxis(500_000_000) == "500M")
        #expect(Format.tokensAxis(1_500_000_000) == "1.5B")
        #expect(Format.tokensAxis(2_000_000_000) == "2B")
        #expect(Format.costAxis(0) == "$0")
        #expect(Format.costAxis(0.25) == "$0.25")
        #expect(Format.costAxis(2.5) == "$2.5")
        #expect(Format.costAxis(600) == "$600")
        #expect(Format.costAxis(1200) == "$1.2K")
        #expect(Format.costAxis(15_000) == "$15K")
    }

    @Test("cost axis labels under a cent stay distinct")
    func subCentCostAxis() {
        // A light 24h range: gridlines a fraction of a cent apart.
        #expect(
            [0, 0.0002, 0.0004].map(Format.costAxis) == ["$0", "$0.0002", "$0.0004"])
        #expect(
            [0.005, 0.01, 0.015, 0.025].map(Format.costAxis)
                == ["$0.005", "$0.01", "$0.015", "$0.025"])
        #expect(Format.costAxis(0.1) == "$0.1")
        #expect(Format.costAxis(0.1 + 0.2) == "$0.3")  // float noise stays hidden
        #expect(Format.costAxis(0.0001 * 3) == "$0.0003")
        #expect(Format.costAxis(-0.005) == "-$0.005")
    }

    @Test("the chart gives way to a note when its tab has nothing to plot")
    func emptyChartNotes() {
        func summary(tokens: Int, cost: Double) -> ActivitySummary {
            ActivitySummary(
                range: .day, bucketStarts: [], bucketUnit: .hour, providers: [],
                totalTokens: tokens, totalCost: cost, sessions: tokens > 0 ? 1 : 0,
                unpricedTokenShare: tokens > 0 && cost == 0 ? 1 : 0)
        }
        let quiet = summary(tokens: 0, cost: 0)
        #expect(ActivityMetric.tokens.emptyChartNote(quiet) == "No activity in this range")
        #expect(ActivityMetric.cost.emptyChartNote(quiet) == "No activity in this range")

        // Only unpriced models: tokens to chart, but no cost.
        let unpriced = summary(tokens: 12_000, cost: 0)
        #expect(ActivityMetric.tokens.emptyChartNote(unpriced) == nil)
        #expect(ActivityMetric.cost.emptyChartNote(unpriced) == "No priced activity in this range")

        let priced = summary(tokens: 12_000, cost: 0.0004)
        #expect(ActivityMetric.tokens.emptyChartNote(priced) == nil)
        #expect(ActivityMetric.cost.emptyChartNote(priced) == nil)
    }

    @Test("shares: always one decimal, never a misleading 0.0%")
    func shares() {
        #expect(Format.share(0) == "0.0%")
        #expect(Format.share(0.947) == "94.7%")
        #expect(Format.share(0.9496) == "95.0%")
        #expect(Format.share(0.898) == "89.8%")
        #expect(Format.share(0.002) == "0.2%")
        #expect(Format.share(0.05) == "5.0%")
        #expect(Format.share(1) == "100.0%")
        #expect(Format.share(0.0004) == "<0.1%")
        #expect(Format.share(0.001) == "0.1%")
        #expect(Format.share(0.9996) == "100.0%")
    }

    @Test("session counts pluralize")
    func sessions() {
        #expect(Format.sessions(0) == "0 sessions")
        #expect(Format.sessions(1) == "1 session")
        #expect(Format.sessions(124) == "124 sessions")
    }

    @Test("the CLI's --now takes ISO 8601 with a zone, or local time without one")
    func cliNow() {
        #expect(
            ActivityCLI.parseNow("2026-09-28T03:45:00Z") == Parse.isoDate("2026-09-28T03:45:00Z"))
        #expect(
            ActivityCLI.parseNow("2026-09-27T23:45:00.500-04:00")
                == Parse.isoDate("2026-09-28T03:45:00.500Z"))
        var local = DateComponents()
        (local.year, local.month, local.day, local.hour, local.minute) = (2026, 9, 27, 23, 45)
        #expect(ActivityCLI.parseNow("2026-09-27T23:45") == Calendar.current.date(from: local))
        #expect(ActivityCLI.parseNow("2026-09-27T23:45:00") == Calendar.current.date(from: local))
        #expect(ActivityCLI.parseNow("yesterday") == nil)
        #expect(ActivityCLI.parseNow("7d") == nil)
    }

    @Test("tab and range labels; the CLI accepts either spelling")
    func labels() {
        #expect(UsageTab.allCases.map(\.label) == ["Limits", "Tokens", "Cost"])
        #expect(ActivityRange.allCases.map(\.label) == ["24h", "7d", "30d", "90d"])
        #expect(ActivityRange(argument: "30d") == .month)
        #expect(ActivityRange(argument: "quarter") == .quarter)
        #expect(ActivityRange(argument: "--tab") == nil)
    }
}
