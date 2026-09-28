import Foundation

/// Reads Codex rollout files. Every line is `{timestamp, type, payload}`;
/// four types matter:
///
/// - `session_meta` names the session (the first one — a forked thread's file
///   repeats its parent's meta after its own);
/// - `turn_context` sets the model for the turns that follow;
/// - `token_usage_record` (newer CLIs) is one API response's usage, with a
///   `response_id` that dedupes it across files;
/// - `event_msg` / `token_count` carries the thread's running total, which
///   is all older CLIs write.
///
/// **Mixed files.** Newer CLIs write both kinds for every response, so once a
/// file has a usage record its token_count events are redundant and stop
/// counting. But a session started on an older CLI and resumed on a newer one
/// has only token_count events up to the resume, and those are the only
/// record of that work: token_count events before the file's first
/// token_usage_record line count, and those after it don't. The running
/// total is tracked through the whole file either way, so the switch can't
/// double count or skip anything.
///
/// **Fork replay.** A thread forked on an older CLI (session_meta has
/// `forked_from_id`, token_count only) begins by replaying its parent's
/// history, token_count events included, re-stamped with the moment of the
/// fork. That usage is the parent's and happened before the fork; counting
/// it again would double it (by tens of millions of tokens on the day of
/// the fork). So replayed events only set the running-total baseline the
/// fork's own events are measured from.
///
/// The replay ends at the fork's first turn of its own: the first
/// turn_context whose `turn_id` is no older than the fork's thread id. Both
/// are UUIDv7s, which begin with their creation time in milliseconds, and a
/// replayed turn keeps the id it was given in the parent, before the fork
/// existed. Every model call happens inside a turn, after its turn_context,
/// so no real event comes before that line — and a fork that was never
/// used past its replay is all replay. Where an id isn't a UUIDv7, time
/// decides instead: the replay is written in one burst (960 lines took
/// 48 ms), while a real response takes seconds, so token_count events
/// stamped within `replayWindow` of the fork's session_meta are the replay.
///
/// Checked against all 17 fork files on the machine this was written on.
/// Eleven replay: every fork from CLIs 0.115–0.145 but one, 2 to 165
/// token_count events each. The rule drops exactly the events whose totals
/// repeat the parent's (where the parent's file still exists) and none
/// after them, and the time rule picks the same events in every file. Forks
/// from 0.154 on replay history without token_count events, so nothing is
/// dropped.
///
/// **Rollback.** Rolling a thread back on a token_count-only CLI puts its
/// running total back where it stood at an earlier turn, and the next turn
/// opens by re-emitting that turn's token_count whole: total and
/// last-response figure alike. The total went down, but it isn't a reset,
/// and that last response was counted the first time round. So a total the
/// file has already reported only moves the baseline, and the responses
/// after it are measured from there. On the machine this was written on,
/// three events in two files (CLIs 0.115 and 0.122) did this, and counting
/// them would have added 245,444 tokens twice; every other drop was a real
/// reset.
final class CodexLogParser: ActivityLogParser {
    private let fallbackSessionId: String
    /// Lines stamped after this are ignored — all of them, so the file reads
    /// exactly as it stood then.
    private let cutoff: Date?
    private var sawSessionMeta = false
    private var sessionId: String?
    private var model = "unknown"
    private var previousTotal: Usage?
    /// Every running total a token_count has reported, so a rollback's
    /// re-emitted one is recognized (see the type's doc comment). Dropped
    /// once the file has usage records: from then on no token_count counts.
    private var seenTotals: Set<Usage> = []
    /// Set by the first token_usage_record line, whether or not it yields a
    /// record: the line's presence is what says the CLI now writes records,
    /// so token_count events from here on are duplicates.
    private var hasUsageRecords = false
    private var replay = ForkReplay.none
    /// In file order: token_count deltas from before the first usage record,
    /// then usage records.
    private(set) var records: [UsageRecord] = []

    /// How long after a fork's session_meta a token_count is taken for the
    /// replay, when ids can't say (see the type's doc comment).
    static let replayWindow: TimeInterval = 1

    private enum ForkReplay {
        /// Not a fork, or its replay is over.
        case none
        /// Replaying until a turn_context whose turn_id is at least this
        /// UUIDv7 millisecond stamp (the fork's thread id's). `forkedAt` is
        /// the fallback if a turn_id turns out not to be a UUIDv7.
        case untilOwnTurn(threadMillis: Int64, forkedAt: Date?)
        /// Replaying until a token_count stamped `replayWindow` or more
        /// after this.
        case untilAfter(Date)
    }

    init(fallbackSessionId: String, until cutoff: Date? = nil) {
        self.fallbackSessionId = fallbackSessionId
        self.cutoff = cutoff
    }

    func consume(_ line: Data, decoder: JSONDecoder) {
        guard let entry = try? decoder.decode(Line.self, from: line),
            let payload = entry.payload
        else { return }
        if let cutoff {
            guard let time = entry.timestamp.flatMap(ActivityTime.parse), time <= cutoff else {
                return
            }
        }
        switch entry.type {
        case "session_meta":
            // The first meta is this thread's; a fork repeats its parent's
            // after it, which must change nothing.
            if !sawSessionMeta {
                sawSessionMeta = true
                if let fork = payload.forked_from_id, !fork.isEmpty {
                    replay = Self.replayState(
                        threadId: payload.id, at: entry.timestamp.flatMap(ActivityTime.parse))
                }
            }
            // Root session first: sub-agent threads carry their parent's, so
            // their tokens count toward the session the user started.
            if sessionId == nil { sessionId = payload.session_id ?? payload.id }
        case "turn_context":
            if let model = payload.model, !model.isEmpty, model != self.model {
                self.model = model
            }
            if case .untilOwnTurn(let threadMillis, let forkedAt) = replay {
                if let turn = Self.uuidV7Millis(payload.turn_id) {
                    if turn >= threadMillis { replay = .none }
                } else {
                    replay = forkedAt.map { .untilAfter($0) } ?? .none
                }
            }
        case "token_usage_record":
            if !hasUsageRecords {
                hasUsageRecords = true
                seenTotals = []
            }
            if let usage = payload.usage,
                let record = makeRecord(usage, entry.timestamp, key: payload.response_id)
            {
                records.append(record)
            }
        case "event_msg":
            guard payload.type == "token_count", let info = payload.info else { return }
            // Always advance the running total — even for events that won't
            // count — so the next delta is measured from the right place.
            let change = delta(total: info.total_token_usage, last: info.last_token_usage)
            guard !hasUsageRecords, !isReplay(entry.timestamp), let change,
                let record = makeRecord(change, entry.timestamp, key: nil)
            else { return }
            records.append(record)
        default:
            return
        }
    }

    /// How a fork's replay will be recognized: by turn ids when the thread
    /// id is a UUIDv7, else by time; neither, if the meta has no timestamp
    /// either (then nothing is taken for replay).
    private static func replayState(threadId: String?, at forkedAt: Date?) -> ForkReplay {
        if let millis = uuidV7Millis(threadId) {
            return .untilOwnTurn(threadMillis: millis, forkedAt: forkedAt)
        }
        return forkedAt.map { .untilAfter($0) } ?? .none
    }

    /// Whether a token_count event stamped `stamp` is part of a fork's
    /// replay. The time rule ends the replay at the first event past the
    /// window; stamps only move forward within a file.
    private func isReplay(_ stamp: String?) -> Bool {
        switch replay {
        case .none:
            return false
        case .untilOwnTurn:
            return true
        case .untilAfter(let forkedAt):
            guard let time = stamp.flatMap(ActivityTime.parse) else { return true }
            if time.timeIntervalSince(forkedAt) < Self.replayWindow { return true }
            replay = .none
            return false
        }
    }

    /// The millisecond timestamp in a UUIDv7's first 48 bits
    /// ("019f9bc9-9822-7063-…" → 0x019f9bc99822); nil for anything that
    /// isn't a canonical version-7 UUID.
    static func uuidV7Millis(_ id: String?) -> Int64? {
        guard let id else { return nil }
        let bytes = Array(id.utf8)
        let dash = UInt8(ascii: "-")
        guard bytes.count == 36, bytes[8] == dash, bytes[13] == dash, bytes[18] == dash,
            bytes[23] == dash, bytes[14] == UInt8(ascii: "7")
        else { return nil }
        var value: Int64 = 0
        for byte in bytes[0..<8] + bytes[9..<13] {
            let digit: UInt8
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = byte - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = byte - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = byte - UInt8(ascii: "A") + 10
            default: return nil
            }
            value = value << 4 | Int64(digit)
        }
        return value
    }

    /// What one token_count event adds. A total the file has reported
    /// before adds nothing: usually it's the same response's total emitted
    /// again, and otherwise a rollback restoring an earlier one. Any other
    /// total that went *down* means the thread's counter reset (e.g. after a
    /// compaction), and the event's own last-response figure is used instead.
    private func delta(total: Usage?, last: Usage?) -> Usage? {
        guard let total else { return last }
        defer { previousTotal = total }
        if !hasUsageRecords, !seenTotals.insert(total).inserted { return nil }
        guard let previous = previousTotal else { return total }
        let diff = total - previous
        if diff.hasNegative { return last }
        return diff.isZero ? nil : diff
    }

    private func makeRecord(_ usage: Usage, _ stamp: String?, key: String?) -> UsageRecord? {
        let tokens = usage.normalized
        guard tokens.total > 0, let stamp, let timestamp = ActivityTime.parse(stamp) else {
            return nil
        }
        return UsageRecord(
            provider: "Codex", timestamp: timestamp, model: model,
            sessionId: sessionId ?? fallbackSessionId,
            dedupeKey: key.flatMap { $0.isEmpty ? nil : $0 }, tokens: tokens)
    }

    private struct Line: Decodable {
        let timestamp: String?
        let type: String?
        let payload: Payload?
    }

    private struct Payload: Decodable {
        let type: String?
        let id: String?
        let session_id: String?
        let forked_from_id: String?
        let turn_id: String?
        let model: String?
        let response_id: String?
        let usage: Usage?
        let info: Info?
    }

    private struct Info: Decodable {
        let total_token_usage: Usage?
        let last_token_usage: Usage?
    }

    /// OpenAI's shape: `input_tokens` *includes* cached reads and cache
    /// writes, and `output_tokens` includes reasoning.
    struct Usage: Decodable, Hashable {
        var input_tokens = 0
        var cached_input_tokens = 0
        var cache_write_input_tokens = 0
        var output_tokens = 0
        var reasoning_output_tokens = 0
        var total_tokens = 0

        init(
            input: Int = 0, cached: Int = 0, cacheWrite: Int = 0, output: Int = 0,
            reasoning: Int = 0, total: Int = 0
        ) {
            input_tokens = input
            cached_input_tokens = cached
            cache_write_input_tokens = cacheWrite
            output_tokens = output
            reasoning_output_tokens = reasoning
            total_tokens = total
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func int(_ key: CodingKeys) -> Int {
                (try? c.decodeIfPresent(Int.self, forKey: key)) ?? 0
            }
            input_tokens = int(.input_tokens)
            cached_input_tokens = int(.cached_input_tokens)
            cache_write_input_tokens = int(.cache_write_input_tokens)
            output_tokens = int(.output_tokens)
            reasoning_output_tokens = int(.reasoning_output_tokens)
            total_tokens = int(.total_tokens)
        }

        private enum CodingKeys: String, CodingKey {
            case input_tokens, cached_input_tokens, cache_write_input_tokens, output_tokens
            case reasoning_output_tokens, total_tokens
        }

        private var fields: [Int] {
            [
                input_tokens, cached_input_tokens, cache_write_input_tokens, output_tokens,
                reasoning_output_tokens, total_tokens,
            ]
        }

        var hasNegative: Bool { fields.contains { $0 < 0 } }
        var isZero: Bool { fields.allSatisfy { $0 == 0 } }

        static func - (lhs: Usage, rhs: Usage) -> Usage {
            Usage(
                input: lhs.input_tokens - rhs.input_tokens,
                cached: lhs.cached_input_tokens - rhs.cached_input_tokens,
                cacheWrite: lhs.cache_write_input_tokens - rhs.cache_write_input_tokens,
                output: lhs.output_tokens - rhs.output_tokens,
                reasoning: lhs.reasoning_output_tokens - rhs.reasoning_output_tokens,
                total: lhs.total_tokens - rhs.total_tokens)
        }

        /// Split into non-overlapping parts, so the sum is `total_tokens`.
        var normalized: TokenCounts {
            TokenCounts(
                input: max(0, input_tokens - cached_input_tokens - cache_write_input_tokens),
                output: output_tokens, cacheRead: cached_input_tokens,
                cacheWrite: cache_write_input_tokens)
        }
    }
}
