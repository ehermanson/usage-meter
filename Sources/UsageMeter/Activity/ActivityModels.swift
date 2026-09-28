import Foundation

/// The dropdown's top-level tabs. Limits is first and the default: it's what
/// the app has always been, and the other two are views onto history.
enum UsageTab: String, CaseIterable, Identifiable {
    case limits, tokens, cost

    var id: String { rawValue }

    var label: String {
        switch self {
        case .limits: return "Limits"
        case .tokens: return "Tokens"
        case .cost: return "Cost"
        }
    }
}

/// How far back the Tokens and Cost tabs look. The day-granular ranges count
/// calendar days *including today* (7d is today and the six before it), so the
/// chart's last point is always the day in progress.
enum ActivityRange: String, CaseIterable, Identifiable, Sendable {
    case day, week, month, quarter

    var id: String { rawValue }

    var label: String {
        switch self {
        case .day: return "24h"
        case .week: return "7d"
        case .month: return "30d"
        case .quarter: return "90d"
        }
    }

    /// Parses a label ("7d") or raw value ("week"), for the CLI.
    init?(argument: String) {
        let match = Self.allCases.first { $0.label == argument || $0.rawValue == argument }
        guard let match else { return nil }
        self = match
    }

    var bucketUnit: Calendar.Component { self == .day ? .hour : .day }

    /// Calendar days covered by a day-bucketed range; nil for the hourly one.
    var dayCount: Int? {
        switch self {
        case .day: return nil
        case .week: return 7
        case .month: return 30
        case .quarter: return 90
        }
    }

    /// Whether a record at `date` falls in the window `window(now:calendar:)`
    /// starts at `start`. 24h is the half-open `(now − 24h, now]`, so an
    /// instant exactly a day old has left it; the day ranges start at a
    /// local midnight, which belongs to them. Nothing after `now` counts in
    /// any range — a skewed clock, or a CLI run pinned to an earlier `now`.
    func includes(_ date: Date, start: Date, now: Date) -> Bool {
        guard date <= now else { return false }
        return self == .day ? date > start : date >= start
    }

    /// The range's window and its contiguous bucket starts, in `calendar`'s
    /// time zone.
    ///
    /// 24h is `now − 24h … now`, bucketed by local clock hour from the hour
    /// containing its start through the hour containing now, so its first
    /// and last buckets are partial (usually 25 of them). The others run from
    /// local midnight N−1 days ago to now, one bucket per calendar day. Every
    /// step is Calendar arithmetic rather than multiples of 3600/86400, so a
    /// 23- or 25-hour DST day is still exactly one bucket.
    func window(now: Date, calendar: Calendar) -> (start: Date, bucketStarts: [Date]) {
        switch self {
        case .day:
            let start = now.addingTimeInterval(-24 * 3600)
            var starts: [Date] = []
            var cursor = calendar.dateInterval(of: .hour, for: start)?.start ?? start
            while cursor <= now {
                starts.append(cursor)
                // Each bucket is one of the calendar's own hours, and the next
                // starts where it ends. An hour added to the start would come
                // off the clock after a half-hour DST change (Lord Howe
                // Island's), leaving every later bucket starting at :30; this
                // way that day has one short hour, or one split in two.
                guard let hour = calendar.dateInterval(of: .hour, for: cursor), hour.end > cursor
                else { break }
                cursor = hour.end
            }
            return (start, starts)
        case .week, .month, .quarter:
            let days = dayCount ?? 7
            let today = calendar.startOfDay(for: now)
            let starts = (0..<days).reversed().compactMap { back in
                calendar.date(byAdding: .day, value: -back, to: today)
                    .map { calendar.startOfDay(for: $0) }
            }
            return (starts.first ?? today, starts)
        }
    }
}

/// One response's tokens, normalized across providers. `input` is *uncached*
/// input only — Codex reports input inclusive of cache reads and writes, and
/// is split apart at parse time — so the four parts never overlap and `total`
/// is the "processed tokens" figure without double counting.
struct TokenCounts: Equatable, Hashable, Sendable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0

    var total: Int { input + output + cacheRead + cacheWrite }

    /// Everything that was read as prompt, cached or not. Tiered prices key
    /// off this: a long-context request is priced by how much it sent.
    var promptTotal: Int { input + cacheRead + cacheWrite }

    static let zero = TokenCounts()

    static func + (lhs: TokenCounts, rhs: TokenCounts) -> TokenCounts {
        TokenCounts(
            input: lhs.input + rhs.input, output: lhs.output + rhs.output,
            cacheRead: lhs.cacheRead + rhs.cacheRead, cacheWrite: lhs.cacheWrite + rhs.cacheWrite)
    }

    /// All four counts zero. Such a record is dropped before copies are
    /// merged: Claude Code logs stray zero copies of real responses, and one
    /// must never stand in for the real line.
    var isZero: Bool { input == 0 && output == 0 && cacheRead == 0 && cacheWrite == 0 }

    /// Component-wise maximum. Two copies of one response disagree only
    /// because one was written mid-stream (Claude Code logs a line per content
    /// block, and the early ones carry a partial output count), so the larger
    /// figure is the final one.
    func merged(with other: TokenCounts) -> TokenCounts {
        TokenCounts(
            input: max(input, other.input), output: max(output, other.output),
            cacheRead: max(cacheRead, other.cacheRead),
            cacheWrite: max(cacheWrite, other.cacheWrite))
    }
}

/// One model response read from a local session log. Deliberately small —
/// a quarter of history is on the order of 100k of these — and holds no raw
/// line content.
struct UsageRecord: Equatable, Sendable {
    /// Matches `UsageStore`'s provider names: "Claude", "Codex".
    let provider: String
    let timestamp: Date
    /// As logged ("claude-opus-5-5[1m]"); normalized only at price lookup.
    var model: String
    let sessionId: String
    /// Identifies the API response across files, for dedupe: Claude's
    /// "message.id:requestId", Codex's response_id. Nil when the log didn't
    /// say, in which case the record is never merged with another.
    let dedupeKey: String?
    var tokens: TokenCounts
    /// The 1-hour cache write as logged (never negative), and not yet
    /// clamped to `tokens.cacheWrite`: copies of one response are merged by
    /// taking the largest of these first, and only the merged figure is
    /// clamped. Read `cacheWrite1h` instead.
    var loggedCacheWrite1h: Int = 0
    /// Anthropic's fast mode, billed at a multiple of standard.
    var fast: Bool = false

    /// The part of `tokens.cacheWrite` written to the 1-hour cache, which
    /// costs more than the default 5-minute write. Clamped to
    /// `0...tokens.cacheWrite`: a log can claim more (one seen here says
    /// 523 of 0), and pricing the excess would make the 5-minute part
    /// negative.
    var cacheWrite1h: Int { min(max(0, loggedCacheWrite1h), tokens.cacheWrite) }
}

/// Everything the Tokens and Cost tabs draw for one range.
struct ActivitySummary: Equatable, Sendable {
    let range: ActivityRange
    /// Contiguous, oldest first; `ProviderActivity`'s bucket arrays are parallel.
    let bucketStarts: [Date]
    let bucketUnit: Calendar.Component
    /// Registry order (Claude, Codex); only providers with logs on this Mac.
    let providers: [ProviderActivity]
    let totalTokens: Int
    let totalCost: Double
    /// Sum of each provider's distinct sessions.
    let sessions: Int
    /// Share of `totalTokens` from models with no known price, 0...1. Their
    /// tokens count everywhere, but they add nothing to the cost.
    let unpricedTokenShare: Double

    /// The providers with anything in the range, in registry order. A
    /// provider can have logs on this Mac and still be idle for a whole range.
    var activeProviders: [ProviderActivity] { providers.filter { $0.tokens > 0 } }
}

struct ProviderActivity: Identifiable, Equatable, Sendable {
    var id: String { name }
    let name: String
    let tokens: Int
    let cost: Double
    let unpricedTokens: Int
    let sessions: Int
    let bucketTokens: [Int]
    let bucketCost: [Double]
}
