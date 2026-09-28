import Foundation

/// Turns scanned records into what the Tokens and Cost tabs show. Pure — no
/// clock, no disk, no globals — so every rule here is pinned by tests with a
/// fixed `now`, calendar, and price table.
enum ActivityAggregator {
    /// The summary of records straight from a scan: `dedupe`, then
    /// `summarize(deduped:…)`.
    static func summarize(
        records: [UsageRecord],
        range: ActivityRange,
        now: Date,
        calendar: Calendar,
        pricing: PricingTable,
        providers: [String] = ActivitySources.all.map(\.name),
        detected: Set<String> = []
    ) -> ActivitySummary {
        summarize(
            deduped: dedupe(records), range: range, now: now, calendar: calendar,
            pricing: pricing, providers: providers, detected: detected)
    }

    /// The summary of records `dedupe` has already been through. Dedupe is
    /// the one step that needs every record at once, and costs the most, so
    /// a caller holding a scan's records runs it once and then summarizes
    /// the result per range or price table — a filter, a sum, and a price
    /// lookup per model.
    static func summarize(
        deduped records: [UsageRecord],
        range: ActivityRange,
        now: Date,
        calendar: Calendar,
        pricing: PricingTable,
        providers: [String] = ActivitySources.all.map(\.name),
        detected: Set<String> = []
    ) -> ActivitySummary {
        let (start, bucketStarts) = range.window(now: now, calendar: calendar)
        let slot = Dictionary(
            providers.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var totals = providers.map { _ in Totals(buckets: bucketStarts.count) }
        var prices: [String: ModelPricing?] = [:]

        for record in records
        where !bucketStarts.isEmpty && range.includes(record.timestamp, start: start, now: now) {
            guard let p = slot[record.provider] else { continue }
            let bucket = bucketIndex(of: record.timestamp, in: bucketStarts)
            let tokens = record.tokens.total
            totals[p].hasRecords = true
            totals[p].tokens += tokens
            totals[p].bucketTokens[bucket] += tokens
            totals[p].sessions.insert(record.sessionId)

            let price: ModelPricing?
            if let cached = prices[record.model] {
                price = cached
            } else {
                price = pricing.pricing(for: record.model)
                prices[record.model] = .some(price)
            }
            if let price {
                let cost = pricing.cost(of: record, with: price)
                totals[p].cost += cost
                totals[p].bucketCost[bucket] += cost
            } else {
                totals[p].unpricedTokens += tokens
            }
        }

        let shown = providers.indices.filter {
            totals[$0].hasRecords || detected.contains(providers[$0])
        }
        let activity = shown.map { i in
            ProviderActivity(
                name: providers[i], tokens: totals[i].tokens, cost: totals[i].cost,
                unpricedTokens: totals[i].unpricedTokens, sessions: totals[i].sessions.count,
                bucketTokens: totals[i].bucketTokens, bucketCost: totals[i].bucketCost)
        }
        let totalTokens = activity.reduce(0) { $0 + $1.tokens }
        let unpriced = activity.reduce(0) { $0 + $1.unpricedTokens }
        return ActivitySummary(
            range: range, bucketStarts: bucketStarts, bucketUnit: range.bucketUnit,
            providers: activity, totalTokens: totalTokens,
            totalCost: activity.reduce(0) { $0 + $1.cost },
            sessions: activity.reduce(0) { $0 + $1.sessions },
            unpricedTokenShare: totalTokens > 0 ? Double(unpriced) / Double(totalTokens) : 0)
    }

    /// Collapses copies of one API response into a single record.
    ///
    /// Claude Code writes a response once per content block and copies
    /// earlier lines into resumed and forked sessions; Codex can repeat a
    /// response record the same way. Copies share a provider-scoped key and
    /// merge as `UsageRecord.merged(with:)` describes: the earliest
    /// timestamp — when the response actually happened — with the largest
    /// counts, since only the last block's line carries the final output
    /// count. Records with all four counts zero are dropped first, so one can
    /// never be the copy that survives. Records without a key are kept as
    /// they are.
    static func dedupe(_ records: [UsageRecord]) -> [UsageRecord] {
        var kept: [UsageRecord] = []
        kept.reserveCapacity(records.count)
        var index: [DedupeKey: Int] = [:]
        index.reserveCapacity(records.count)
        for record in records where !record.tokens.isZero {
            guard let key = record.dedupeKey else {
                kept.append(record)
                continue
            }
            let scoped = DedupeKey(provider: record.provider, key: key)
            if let i = index[scoped] {
                kept[i] = kept[i].merged(with: record)
            } else {
                index[scoped] = kept.count
                kept.append(record)
            }
        }
        return kept
    }

    /// Deduped records inside `range`, for callers (the CLI) that break the
    /// summary down further.
    static func records(
        _ records: [UsageRecord], in range: ActivityRange, now: Date, calendar: Calendar
    ) -> [UsageRecord] {
        self.records(deduped: dedupe(records), in: range, now: now, calendar: calendar)
    }

    /// The records inside `range`, of ones already deduped.
    static func records(
        deduped records: [UsageRecord], in range: ActivityRange, now: Date, calendar: Calendar
    ) -> [UsageRecord] {
        let start = range.window(now: now, calendar: calendar).start
        return records.filter { range.includes($0.timestamp, start: start, now: now) }
    }

    /// The last bucket starting at or before `date`. Binary search against
    /// the precomputed starts, rather than Calendar math per record, keeps
    /// DST handling in one place (`ActivityRange.window`) and is fast.
    static func bucketIndex(of date: Date, in starts: [Date]) -> Int {
        var low = 0
        var high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= date { low = mid } else { high = mid - 1 }
        }
        return low
    }

    private struct DedupeKey: Hashable {
        let provider: String
        let key: String
    }

    private struct Totals {
        var hasRecords = false
        var tokens = 0
        var cost = 0.0
        var unpricedTokens = 0
        var sessions = Set<String>()
        var bucketTokens: [Int]
        var bucketCost: [Double]

        init(buckets: Int) {
            bucketTokens = Array(repeating: 0, count: buckets)
            bucketCost = Array(repeating: 0, count: buckets)
        }
    }
}
