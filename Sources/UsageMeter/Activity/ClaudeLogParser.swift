import Foundation

/// Reads Claude Code transcripts. The lines that matter are assistant turns
/// carrying `message.usage`; everything else (user turns, tool results,
/// summaries) is skipped.
///
/// Claude Code writes one line *per content block* of a response, each with
/// the same `message.id` and `requestId`, and a resumed or forked session
/// copies earlier lines into its new file. The copies don't agree: the early
/// ones are written mid-stream, with a partial output count and no `speed`,
/// and a stray copy can carry no counts at all. So a copy whose four counts
/// are all zero is dropped outright, and the rest merge (see
/// `UsageRecord.merged(with:)`). Consecutive copies within a file are merged
/// here, which roughly halves what's kept; copies across files are merged by
/// `ActivityAggregator`, which sees every file at once.
final class ClaudeLogParser: ActivityLogParser {
    private(set) var records: [UsageRecord] = []
    private let fallbackSessionId: String
    /// Lines stamped after this are ignored, before any merging.
    private let cutoff: Date?
    /// Reused so every record from this file shares one string's storage.
    private var lastSession = ""
    private var lastModel = ""

    init(fallbackSessionId: String, until cutoff: Date? = nil) {
        self.fallbackSessionId = fallbackSessionId
        self.cutoff = cutoff
    }

    func consume(_ line: Data, decoder: JSONDecoder) {
        guard let entry = try? decoder.decode(Line.self, from: line),
            entry.type == "assistant", let message = entry.message,
            let usage = message.usage
        else { return }
        let model = message.model ?? "unknown"
        // Client-side placeholders (errors, interrupted turns) — never billed.
        guard model != "<synthetic>" else { return }

        let tokens = TokenCounts(
            input: usage.input_tokens ?? 0, output: usage.output_tokens ?? 0,
            cacheRead: usage.cache_read_input_tokens ?? 0,
            cacheWrite: usage.cache_creation_input_tokens ?? 0)
        // Before any merging: a zero copy sharing a real response's key and
        // timestamp must not be the copy that survives.
        guard !tokens.isZero, let stamp = entry.timestamp,
            let timestamp = ActivityTime.parse(stamp)
        else { return }
        // Not yet written, as far as a pinned `--now` is concerned.
        if let cutoff, timestamp > cutoff { return }

        let key: String?
        if let id = message.id, !id.isEmpty, let request = entry.requestId, !request.isEmpty {
            key = "\(id):\(request)"
        } else {
            key = nil
        }
        let record = UsageRecord(
            provider: "Claude", timestamp: timestamp, model: intern(model, &lastModel),
            sessionId: intern(entry.sessionId ?? fallbackSessionId, &lastSession),
            dedupeKey: key, tokens: tokens,
            loggedCacheWrite1h: max(0, usage.cache_creation?.ephemeral_1h_input_tokens ?? 0),
            fast: usage.speed == "fast")

        // Another block of the response just recorded: fold it in (see
        // `UsageRecord.merged(with:)`). The later line's counts win where
        // larger (its output count is final), the earlier line's timestamp
        // stays.
        if let key, let last = records.last, last.dedupeKey == key {
            records[records.count - 1] = last.merged(with: record)
        } else {
            records.append(record)
        }
    }

    private func intern(_ value: String, _ last: inout String) -> String {
        if value != last { last = value }
        return last
    }

    /// Only the fields read; the decoder skips the rest (including the
    /// message content that makes these lines large) without building it.
    private struct Line: Decodable {
        let type: String?
        let timestamp: String?
        let sessionId: String?
        let requestId: String?
        let message: Message?
    }

    private struct Message: Decodable {
        let id: String?
        let model: String?
        let usage: Usage?
    }

    private struct Usage: Decodable {
        let input_tokens: Int?
        let output_tokens: Int?
        let cache_read_input_tokens: Int?
        let cache_creation_input_tokens: Int?
        let cache_creation: CacheCreation?
        let speed: String?
    }

    private struct CacheCreation: Decodable {
        let ephemeral_1h_input_tokens: Int?
    }
}

extension UsageRecord {
    /// Folds a second copy of the same response into this one:
    ///
    /// - each count is the largest either copy logged (see
    ///   `TokenCounts.merged(with:)`), and so is the 1-hour cache write,
    ///   which `cacheWrite1h` then clamps to the merged cache write;
    /// - fast if either copy says so — the mid-stream copies omit `speed`;
    /// - the earliest timestamp, when the response actually happened, with
    ///   the session that goes with it;
    /// - the model of the copy with the largest output, the final one (they
    ///   should all agree anyway).
    ///
    /// Associative and, up to ties, commutative, so the result doesn't depend
    /// on the order copies are met in.
    func merged(with other: UsageRecord) -> UsageRecord {
        var result = other.timestamp < timestamp ? other : self
        result.model = other.tokens.output > tokens.output ? other.model : model
        result.tokens = tokens.merged(with: other.tokens)
        result.loggedCacheWrite1h = max(loggedCacheWrite1h, other.loggedCacheWrite1h)
        result.fast = fast || other.fast
        return result
    }
}
