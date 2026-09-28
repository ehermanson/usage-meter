import Foundation
import Testing

@testable import UsageMeter

private func calendar(_ zone: String) -> Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: zone)!
    return cal
}

private func date(_ iso: String) -> Date { Parse.isoDate(iso)! }

private func record(
    _ provider: String = "Claude", at timestamp: Date, model: String = "priced",
    session: String = "s1", key: String? = nil, tokens: TokenCounts = TokenCounts(input: 100),
    oneHour: Int = 0, fast: Bool = false
) -> UsageRecord {
    UsageRecord(
        provider: provider, timestamp: timestamp, model: model, sessionId: session,
        dedupeKey: key, tokens: tokens, loggedCacheWrite1h: oneHour, fast: fast)
}

/// $1 per input token, so costs read as token counts.
private let pricing = PricingTable(models: [
    "priced": ModelPricing(base: .init(input: 1, output: 1))
])

private func summarize(
    _ records: [UsageRecord], _ range: ActivityRange, now: Date,
    calendar cal: Calendar = calendar("America/New_York"), detected: Set<String> = []
) -> ActivitySummary {
    ActivityAggregator.summarize(
        records: records, range: range, now: now, calendar: cal, pricing: pricing,
        providers: ["Claude", "Codex"], detected: detected)
}

@Suite("Activity aggregation")
struct ActivityAggregatorTests {
    let ny = calendar("America/New_York")

    @Test("bucket counts, units and alignment per range")
    func bucketsPerRange() throws {
        let now = date("2026-09-27T18:40:00-04:00")
        let day = summarize([], .day, now: now)
        #expect(day.bucketUnit == .hour)
        #expect(day.bucketStarts.count == 25)  // 18:00 yesterday … 18:00 today
        #expect(day.bucketStarts.first == date("2026-09-26T18:00:00-04:00"))
        #expect(day.bucketStarts.last == date("2026-09-27T18:00:00-04:00"))

        for (range, days) in [(ActivityRange.week, 7), (.month, 30), (.quarter, 90)] {
            let s = summarize([], range, now: now)
            #expect(s.bucketUnit == .day)
            #expect(s.bucketStarts.count == days)
            #expect(s.bucketStarts.allSatisfy { ny.startOfDay(for: $0) == $0 })
            #expect(s.bucketStarts.last == date("2026-09-27T00:00:00-04:00"))
            #expect(zip(s.bucketStarts, s.bucketStarts.dropFirst()).allSatisfy { $0 < $1 })
        }
        let week = summarize([], .week, now: now)
        #expect(week.bucketStarts.first == date("2026-09-21T00:00:00-04:00"))
    }

    @Test("every bucket is present, zeros included, and buckets sum to the totals")
    func zeroBuckets() throws {
        let now = date("2026-09-27T18:40:00-04:00")
        let s = summarize(
            [
                record(at: date("2026-09-23T10:00:00-04:00"), tokens: TokenCounts(input: 5)),
                record(at: date("2026-09-23T23:59:59-04:00"), tokens: TokenCounts(input: 7)),
                record(at: date("2026-09-27T18:39:00-04:00"), tokens: TokenCounts(output: 11)),
            ], .week, now: now)
        let claude = try #require(s.providers.first)
        #expect(claude.bucketTokens == [0, 0, 12, 0, 0, 0, 11])
        #expect(claude.bucketCost == [0, 0, 12, 0, 0, 0, 11])
        #expect(claude.tokens == 23)
        #expect(claude.cost == 23)
        #expect(s.totalTokens == 23)
    }

    @Test("the window runs from the range start through now")
    func windowEdges() {
        let now = date("2026-09-27T18:40:00-04:00")
        let s = summarize(
            [
                record(at: date("2026-09-20T23:59:59-04:00")),  // day before 7d starts
                record(at: date("2026-09-21T00:00:00-04:00")),  // first instant
                record(at: now),
                record(at: now.addingTimeInterval(1)),  // future: a skewed clock
            ], .week, now: now)
        #expect(s.totalTokens == 200)

        // 24h is (now − 24h, now]: exactly a day old has left the window.
        let day = summarize(
            [
                record(at: now.addingTimeInterval(-24 * 3600 - 1)),
                record(at: now.addingTimeInterval(-24 * 3600)),
                record(at: now.addingTimeInterval(-24 * 3600 + 0.001)),
                record(at: now.addingTimeInterval(-60)),
                record(at: now),
                record(at: now.addingTimeInterval(0.001)),
            ], .day, now: now)
        #expect(day.totalTokens == 300)
        #expect(day.providers.first?.bucketTokens.first == 100)  // partial first hour
        #expect(day.providers.first?.bucketTokens.last == 200)
        #expect(
            ActivityAggregator.records(
                [record(at: now.addingTimeInterval(-24 * 3600)), record(at: now)], in: .day,
                now: now, calendar: ny
            ).count == 1)
    }

    @Test("24h: 25 local-hour buckets from the hour holding now − 24h to the hour holding now")
    func dayBucketsInHalfHourZone() throws {
        // In a half-hour zone the buckets follow local clock hours, not UTC.
        let kolkata = calendar("Asia/Kolkata")
        let now = date("2026-09-27T18:10:00+05:30")
        let s = summarize(
            [
                record(at: date("2026-09-26T18:10:00.001+05:30")),  // first, partial
                record(at: date("2026-09-27T17:59:59+05:30")),
                record(at: date("2026-09-27T18:05:00+05:30")),  // last, partial
            ], .day, now: now, calendar: kolkata)
        #expect(s.bucketStarts.count == 25)
        #expect(s.bucketStarts.first == date("2026-09-26T18:00:00+05:30"))
        #expect(s.bucketStarts.last == date("2026-09-27T18:00:00+05:30"))
        let buckets = try #require(s.providers.first?.bucketTokens)
        #expect(buckets.first == 100)
        #expect(buckets[23] == 100)
        #expect(buckets.last == 100)
    }

    @Test("a 25-hour DST day is one daily bucket")
    func dstFallBackDay() throws {
        // US DST ends 2026-11-01 at 2:00 EDT → 1:00 EST.
        let now = date("2026-11-03T12:00:00-05:00")
        let s = summarize(
            [
                // 23:30 on Nov 1 is 24h30m after its midnight: a fixed 86400s
                // bucket would misfile it into Nov 2.
                record(at: date("2026-11-01T23:30:00-05:00"), tokens: TokenCounts(input: 3)),
                record(at: date("2026-11-02T00:30:00-05:00"), tokens: TokenCounts(input: 4)),
            ], .week, now: now, calendar: ny)
        #expect(s.bucketStarts.count == 7)
        let nov1 = try #require(s.bucketStarts.firstIndex(of: date("2026-11-01T00:00:00-04:00")))
        #expect(s.bucketStarts[nov1 + 1] == date("2026-11-02T00:00:00-05:00"))
        #expect(s.bucketStarts[nov1 + 1].timeIntervalSince(s.bucketStarts[nov1]) == 25 * 3600)
        let buckets = try #require(s.providers.first?.bucketTokens)
        #expect(buckets[nov1] == 3)
        #expect(buckets[nov1 + 1] == 4)
    }

    @Test("a 23-hour DST day is one daily bucket, and hours stay an hour apart")
    func dstSpringForward() throws {
        // US DST starts 2026-03-08 at 2:00 EST → 3:00 EDT.
        let now = date("2026-03-08T12:00:00-04:00")
        let week = summarize([], .week, now: now, calendar: ny)
        #expect(week.bucketStarts.last == date("2026-03-08T00:00:00-05:00"))
        #expect(week.bucketStarts.allSatisfy { ny.startOfDay(for: $0) == $0 })

        let day = summarize(
            [record(at: date("2026-03-08T03:15:00-04:00"))], .day, now: now, calendar: ny)
        #expect(day.bucketStarts.count == 25)
        let gaps = zip(day.bucketStarts, day.bucketStarts.dropFirst()).map {
            $1.timeIntervalSince($0)
        }
        #expect(gaps.allSatisfy { $0 == 3600 })
        let i = try #require(day.bucketStarts.firstIndex(of: date("2026-03-08T03:00:00-04:00")))
        #expect(day.providers.first?.bucketTokens[i] == 100)

        // And across the fall-back, the repeated 1 AM hour is two buckets.
        let fall = summarize([], .day, now: date("2026-11-01T12:00:00-05:00"), calendar: ny)
        #expect(fall.bucketStarts.count == 25)
        #expect(
            zip(fall.bucketStarts, fall.bucketStarts.dropFirst()).allSatisfy {
                $1.timeIntervalSince($0) == 3600
            })
    }

    @Test("24h keeps to local clock hours across a half-hour DST change")
    func halfHourDST() throws {
        // Lord Howe Island moves its clocks half an hour at 2:00: forward on
        // 2026-10-04 (+10:30 → +11:00), back on 2026-04-05.
        let lordHowe = calendar("Australia/Lord_Howe")
        func clock(_ starts: [Date]) -> [String] {
            starts.map {
                let c = lordHowe.dateComponents([.hour, .minute], from: $0)
                return String(format: "%02d:%02d", c.hour ?? -1, c.minute ?? -1)
            }
        }
        func hours(_ range: ClosedRange<Int>) -> [String] {
            range.map { String(format: "%02d:00", $0) }
        }

        // The clock skips 2:00–2:30, so 2 AM is a half-hour bucket from 2:30;
        // every other bucket, before and after, starts on the hour.
        let spring = summarize(
            [
                record(at: date("2026-10-04T01:45:00+10:30"), tokens: TokenCounts(input: 1)),
                record(at: date("2026-10-04T02:45:00+11:00"), tokens: TokenCounts(input: 2)),
                record(at: date("2026-10-04T22:50:00+11:00"), tokens: TokenCounts(input: 3)),
                record(at: date("2026-10-04T23:10:00+11:00"), tokens: TokenCounts(input: 4)),
            ], .day, now: date("2026-10-04T23:20:00+11:00"), calendar: lordHowe)
        #expect(
            clock(spring.bucketStarts)
                == ["22:00", "23:00", "00:00", "01:00", "02:30"] + hours(3...23))
        #expect(spring.bucketStarts.first == date("2026-10-03T22:00:00+10:30"))
        let springTokens = try #require(spring.providers.first?.bucketTokens)
        #expect(springTokens[3] == 1)
        #expect(springTokens[4] == 2)
        #expect(springTokens.suffix(2) == [3, 4])

        // The clock repeats 1:30–2:00, which is a bucket of its own, as a
        // whole repeated hour is.
        let fall = summarize(
            [
                record(at: date("2026-04-05T01:45:00+11:00"), tokens: TokenCounts(input: 1)),
                record(at: date("2026-04-05T01:45:00+10:30"), tokens: TokenCounts(input: 2)),
                record(at: date("2026-04-05T22:10:00+10:30"), tokens: TokenCounts(input: 3)),
            ], .day, now: date("2026-04-05T22:50:00+10:30"), calendar: lordHowe)
        #expect(
            clock(fall.bucketStarts) == ["23:00", "00:00", "01:00", "01:30"] + hours(2...22))
        let fallTokens = try #require(fall.providers.first?.bucketTokens)
        #expect(fallTokens[2] == 1)
        #expect(fallTokens[3] == 2)
        #expect(fallTokens.last == 3)
    }

    @Test("sessions are distinct per provider and summed across providers")
    func sessions() throws {
        let now = date("2026-09-27T18:40:00-04:00")
        let t = date("2026-09-27T10:00:00-04:00")
        let s = summarize(
            [
                record(at: t, session: "a"), record(at: t, session: "a"),
                record(at: t, session: "b"),
                record("Codex", at: t, session: "a"),  // same id, other provider
            ], .week, now: now)
        #expect(s.providers.map(\.sessions) == [2, 1])
        #expect(s.sessions == 3)
    }

    @Test("unpriced models count as tokens but not cost, and report their share")
    func unpricedShare() throws {
        let now = date("2026-09-27T18:40:00-04:00")
        let t = date("2026-09-27T10:00:00-04:00")
        let s = summarize(
            [
                record(at: t, tokens: TokenCounts(input: 997)),
                record("Codex", at: t, model: "mystery", tokens: TokenCounts(input: 3)),
            ], .week, now: now)
        #expect(s.totalTokens == 1000)
        #expect(s.totalCost == 997)
        #expect(s.providers[1].unpricedTokens == 3)
        #expect(s.providers[1].cost == 0)
        #expect(abs(s.unpricedTokenShare - 0.003) < 1e-12)
        #expect(summarize([], .week, now: now).unpricedTokenShare == 0)
    }

    @Test("copies of a response merge across files: earliest time, largest counts")
    func dedupeAcrossFiles() throws {
        let now = date("2026-09-27T18:40:00-04:00")
        let early = date("2026-09-26T23:59:00-04:00")
        let late = date("2026-09-27T00:05:00-04:00")
        let s = summarize(
            [
                // A resumed session's copy (later file, later time) with the
                // final output count; the original with a partial one.
                record(
                    at: late, session: "resumed", key: "m:r",
                    tokens: TokenCounts(input: 5, output: 90)),
                record(
                    at: early, session: "original", key: "m:r",
                    tokens: TokenCounts(input: 5, output: 8)),
                record("Codex", at: late, key: "m:r"),  // same key, other provider: distinct
            ], .week, now: now)
        let claude = s.providers[0]
        #expect(claude.tokens == 95)
        #expect(claude.bucketTokens[5] == 95)  // Sep 26, the earliest copy's day
        #expect(claude.sessions == 1)
        #expect(s.providers[1].tokens == 100)

        let merged = ActivityAggregator.dedupe([
            record(
                at: late, session: "resumed", key: "k", tokens: TokenCounts(input: 5, output: 90)),
            record(
                at: early, session: "original", key: "k", tokens: TokenCounts(input: 5, output: 8)),
            record(at: late, key: nil), record(at: late, key: nil),
        ])
        #expect(merged.count == 3)
        #expect(merged[0].timestamp == early)
        #expect(merged[0].sessionId == "original")
        #expect(merged[0].tokens == TokenCounts(input: 5, output: 90))
    }

    @Test("merging across files: zero copies dropped first, fast OR'd, 1h clamped last")
    func mergeRulesAcrossFiles() throws {
        let now = date("2026-09-27T18:40:00-04:00")
        let early = date("2026-09-27T10:00:00-04:00")
        let late = date("2026-09-27T10:00:30-04:00")
        let zeroFirst = date("2026-09-26T09:00:00-04:00")
        let merged = ActivityAggregator.dedupe([
            // A zero copy, earliest of all and claiming a 1h write: dropped
            // before merging, so neither its time nor its 1h figure survive.
            record(at: zeroFirst, model: "zero", key: "k", tokens: .zero, oneHour: 523),
            // The partial copy: no speed, small output, a malformed 1h
            // figure above its own write.
            record(
                at: early, model: "partial", key: "k",
                tokens: TokenCounts(output: 8, cacheWrite: 100), oneHour: 300),
            // The final copy: fast, full output, a bigger write.
            record(
                at: late, model: "final", key: "k",
                tokens: TokenCounts(output: 4355, cacheWrite: 400), oneHour: 0, fast: true),
            record(at: late, key: nil, tokens: .zero),  // unkeyed zero: dropped too
        ])
        let only = try #require(merged.first)
        #expect(merged.count == 1)
        #expect(only.timestamp == early)
        #expect(only.model == "final")
        #expect(only.tokens == TokenCounts(output: 4355, cacheWrite: 400))
        #expect(only.fast)
        #expect(only.cacheWrite1h == 300)  // max(300, 0), within 400

        // With a smaller merged write, the max is clamped to it.
        let clamped = ActivityAggregator.dedupe([
            record(at: early, key: "c", tokens: TokenCounts(cacheWrite: 100), oneHour: 700),
            record(at: late, key: "c", tokens: TokenCounts(cacheWrite: 250)),
        ])
        #expect(clamped.first?.cacheWrite1h == 250)

        // In a summary, the zero copy's day stays empty.
        let s = summarize(
            [
                record(at: zeroFirst, key: "k", tokens: .zero),
                record(at: early, key: "k", tokens: TokenCounts(output: 50)),
            ], .week, now: now)
        #expect(s.providers.first?.bucketTokens.suffix(2) == [0, 50])
    }

    @Test("providers: registry order; shown with records in range or logs on disk")
    func providerInclusion() {
        let now = date("2026-09-27T18:40:00-04:00")
        let t = date("2026-09-27T10:00:00-04:00")
        #expect(summarize([], .week, now: now).providers.isEmpty)
        #expect(
            summarize([], .week, now: now, detected: ["Codex"]).providers.map(\.name) == ["Codex"])
        let zeros = summarize([], .week, now: now, detected: ["Codex"]).providers[0]
        #expect(zeros.tokens == 0 && zeros.bucketTokens == Array(repeating: 0, count: 7))
        #expect(
            summarize([record("Codex", at: t), record(at: t)], .week, now: now).providers.map(
                \.name)
                == ["Claude", "Codex"])
        // Out of range and not detected: hidden.
        #expect(
            summarize([record(at: date("2026-01-01T00:00:00Z"))], .week, now: now).providers
                .isEmpty)
    }

    @Test("deduping once and summarizing per range gives the same summaries as raw records")
    func dedupeOnceThenSummarize() {
        let now = date("2026-09-27T18:40:00-04:00")
        let raw = [
            record(
                at: date("2026-09-27T10:00:30-04:00"), key: "k", tokens: TokenCounts(output: 90)),
            record(at: date("2026-09-27T10:00:00-04:00"), key: "k", tokens: TokenCounts(output: 8)),
            record(at: date("2026-09-20T09:00:00-04:00"), key: "old"),
            record("Codex", at: date("2026-09-27T12:00:00-04:00"), key: "k"),
            record(at: date("2026-09-27T11:00:00-04:00"), key: nil, tokens: .zero),
            record(at: date("2026-06-30T11:00:00-04:00"), session: "s2"),
        ]
        let deduped = ActivityAggregator.dedupe(raw)
        for range in ActivityRange.allCases {
            let once = ActivityAggregator.summarize(
                deduped: deduped, range: range, now: now, calendar: ny, pricing: pricing,
                providers: ["Claude", "Codex"])
            #expect(once == summarize(raw, range, now: now), "\(range)")
            #expect(
                ActivityAggregator.records(deduped: deduped, in: range, now: now, calendar: ny)
                    == ActivityAggregator.records(raw, in: range, now: now, calendar: ny),
                "\(range)")
        }
    }

    @Test("bucket lookup finds the last start at or before a date")
    func bucketIndex() {
        let starts = (0..<5).map { Date(timeIntervalSince1970: Double($0) * 10) }
        #expect(ActivityAggregator.bucketIndex(of: Date(timeIntervalSince1970: 0), in: starts) == 0)
        #expect(
            ActivityAggregator.bucketIndex(of: Date(timeIntervalSince1970: 9.9), in: starts) == 0)
        #expect(
            ActivityAggregator.bucketIndex(of: Date(timeIntervalSince1970: 10), in: starts) == 1)
        #expect(
            ActivityAggregator.bucketIndex(of: Date(timeIntervalSince1970: 99), in: starts) == 4)
    }
}
