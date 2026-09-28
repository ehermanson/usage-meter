import Foundation

/// `UsageMeter --activity [24h|7d|30d|90d] [--now <ISO 8601>]`: the Tokens
/// and Cost tabs' numbers, printed exactly (integers, and costs to four
/// places) alongside the formatted ones, so they can be diffed against an
/// independent count of the same logs. Also times a cold and a warm scan, the
/// two figures that decide whether the tabs feel instant.
///
/// `--now` pins the moment the range ends: the window is laid out from it,
/// and log lines stamped after it are ignored before anything is merged —
/// the logs as they stood then — so two runs minutes apart, or this and an
/// independent count, agree exactly while the logs keep growing.
enum ActivityCLI {
    static func run(range: ActivityRange, now pinned: Date? = nil) async {
        let calendar = Calendar.current
        var pricing = ModelPriceCatalog.loadCached()
        if let fresh = await ModelPriceCatalog.refreshIfNeeded() { pricing = fresh }

        // The scanner runs on its own utility queue, as it does in the app,
        // so the timings are the ones the app gets. The age cutoff follows
        // the pinned now, so an earlier window still sees every file it could
        // hold records from.
        let scanner = ActivityScanner(sources: ActivitySources.all(until: pinned))
        let scanNow = pinned ?? .now
        let cold = await scanner.scan(now: scanNow)
        let warm = await scanner.scan(now: scanNow)
        let now = pinned ?? .now
        // Deduped once and then summarized, the way the app does it.
        let started = Date.now
        let deduped = ActivityAggregator.dedupe(warm.records)
        let summary = ActivityAggregator.summarize(
            deduped: deduped, range: range, now: now, calendar: calendar, pricing: pricing,
            detected: warm.detectedProviders)
        let aggregateTime = Date.now.timeIntervalSince(started)

        let stamp = DateFormatter()
        stamp.calendar = calendar
        stamp.timeZone = calendar.timeZone
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd HH:mm"
        let window = range.window(now: now, calendar: calendar)

        print("UsageMeter activity — \(range.label)\(pinned == nil ? "" : " (now pinned)")")
        print(
            "window: \(stamp.string(from: window.start)) → \(stamp.string(from: now))"
                + " (\(calendar.timeZone.identifier)), \(summary.bucketStarts.count)"
                + " \(range.bucketUnit == .hour ? "hourly" : "daily") buckets")
        switch pricing.source {
        case .bundled:
            print("pricing: bundled snapshot (\(pricing.models.count) models)")
        case .downloaded(let fetched):
            print(
                "pricing: LiteLLM, fetched \(stamp.string(from: fetched)), over the bundled"
                    + " snapshot (\(pricing.models.count) models)")
        }
        print(
            "scan: \(cold.stats.files) files, \(megabytes(cold.stats.bytesRead)) MB,"
                + " cold \(millis(cold.stats.duration)) ms; warm rescan"
                + " \(millis(warm.stats.duration)) ms (\(warm.stats.filesRead) files read);"
                + " aggregate \(millis(aggregateTime)) ms; \(warm.records.count) records")
        print("")
        print(
            "TOTAL   tokens \(summary.totalTokens) (\(Format.tokens(summary.totalTokens)))"
                + "  cost \(fixed(summary.totalCost)) (\(Format.cost(summary.totalCost)))"
                + "  sessions \(summary.sessions)"
                + "  unpriced \(fixed(summary.unpricedTokenShare * 100, 3))%")
        for p in summary.providers {
            print(
                "\(pad(p.name, 7)) tokens \(p.tokens) (\(Format.tokens(p.tokens)))"
                    + "  cost \(fixed(p.cost)) (\(Format.cost(p.cost)))"
                    + "  sessions \(p.sessions)  unpriced_tokens \(p.unpricedTokens)")
        }

        print("")
        print("by model (deduped, in range):")
        let inRange = ActivityAggregator.records(
            deduped: deduped, in: range, now: now, calendar: calendar)
        var byModel: [String: (provider: String, model: String, tokens: TokenCounts, long: Int)] =
            [:]
        var costs: [String: Double] = [:]
        for record in inRange {
            let key = "\(record.provider)\u{1}\(record.model)"
            var entry = byModel[key] ?? (record.provider, record.model, .zero, 0)
            entry.tokens = entry.tokens + record.tokens
            entry.long += record.cacheWrite1h
            byModel[key] = entry
            if let cost = pricing.cost(of: record) { costs[key, default: 0] += cost }
        }
        for (key, entry) in byModel.sorted(by: { $0.value.tokens.total > $1.value.tokens.total }) {
            let cost = costs[key].map { fixed($0) } ?? "unpriced"
            print(
                "  \(pad(entry.provider, 6)) \(pad(entry.model, 28)) total \(entry.tokens.total)"
                    + "  in \(entry.tokens.input)  out \(entry.tokens.output)"
                    + "  cache_read \(entry.tokens.cacheRead)"
                    + "  cache_write \(entry.tokens.cacheWrite) (1h \(entry.long))  cost \(cost)")
        }

        print("")
        print("buckets (tokens / cost per provider):")
        stamp.dateFormat = range.bucketUnit == .hour ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd      "
        for (i, start) in summary.bucketStarts.enumerated() {
            let cells = summary.providers.map {
                "\($0.name) \($0.bucketTokens[i]) / \(fixed($0.bucketCost[i]))"
            }
            print("  \(stamp.string(from: start))  \(cells.joined(separator: "   "))")
        }
    }

    /// `--now`'s value: ISO 8601 with a zone ("2026-09-27T23:00:00Z",
    /// "…-04:00", fractions allowed), or without one for local time
    /// ("2026-09-27T19:00" or with seconds).
    static func parseNow(_ text: String) -> Date? {
        if let date = ActivityTime.parse(text) { return date }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss"] {
            local.dateFormat = format
            if let date = local.date(from: text) { return date }
        }
        return nil
    }

    private static func fixed(_ value: Double, _ places: Int = 4) -> String {
        String(format: "%.*f", places, value)
    }

    private static func millis(_ seconds: TimeInterval) -> String {
        String(format: "%.0f", seconds * 1000)
    }

    private static func megabytes(_ bytes: Int64) -> String {
        String(format: "%.0f", Double(bytes) / 1_000_000)
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }
}
