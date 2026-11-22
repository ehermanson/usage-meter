import Foundation

/// Reads Antigravity CLI (`agy`) transcripts at
/// `<home>/antigravity-cli/brain/<id>/.system_generated/logs/transcript_full.jsonl`.
///
/// Each line is one step; `PLANNER_RESPONSE` steps are model turns carrying
/// `model`, `input_tokens` (uncached), `cache_read_tokens`, `output_tokens`,
/// `created_at`, and `step_index`. Every other step type (user prompts, tool
/// results, errors) is skipped.
final class AntigravityLogParser: ActivityLogParser {
    private var rawRecords: [UsageRecord] = []
    private let conversationId: String
    private let sessionResolver: () -> String
    /// Lines stamped after this are ignored; see `ActivitySources.all(until:)`.
    private let cutoff: Date?
    /// Reused so consecutive records with the same model share one string buffer.
    private var lastModel = ""

    /// Resolves `sessionId` dynamically so a subagent transcript first scanned
    /// just before its parent's `subagents/<child>.json` lands on disk picks up
    /// the parent session id on the next rebuild without re-reading the file.
    var records: [UsageRecord] {
        let currentSession = sessionResolver()
        return rawRecords.map { record in
            guard record.sessionId != currentSession else { return record }
            return UsageRecord(
                provider: record.provider, timestamp: record.timestamp, model: record.model,
                sessionId: currentSession, dedupeKey: record.dedupeKey, tokens: record.tokens,
                loggedCacheWrite1h: record.loggedCacheWrite1h, fast: record.fast)
        }
    }

    init(
        conversationId: String,
        sessionResolver: @escaping () -> String,
        until cutoff: Date? = nil
    ) {
        self.conversationId = conversationId
        self.sessionResolver = sessionResolver
        self.cutoff = cutoff
    }

    convenience init(
        conversationId: String, sessionId: String? = nil, until cutoff: Date? = nil
    ) {
        let resolved = sessionId ?? conversationId
        self.init(conversationId: conversationId, sessionResolver: { resolved }, until: cutoff)
    }

    func consume(_ line: Data, decoder: JSONDecoder) {
        guard let entry = try? decoder.decode(Line.self, from: line),
            entry.type == "PLANNER_RESPONSE"
        else { return }

        let tokens = TokenCounts(
            input: max(0, entry.input_tokens ?? 0),
            output: max(0, entry.output_tokens ?? 0),
            cacheRead: max(0, entry.cache_read_tokens ?? 0),
            cacheWrite: max(0, entry.cache_creation_tokens ?? 0)
        )
        guard !tokens.isZero, let stamp = entry.created_at,
            let timestamp = ActivityTime.parse(stamp)
        else { return }
        if let cutoff, timestamp > cutoff { return }

        let key = entry.step_index.map { "\(conversationId):\($0)" }
        let model = intern(entry.model ?? "unknown", &lastModel)
        rawRecords.append(
            UsageRecord(
                provider: "Antigravity", timestamp: timestamp, model: model,
                sessionId: sessionResolver(), dedupeKey: key, tokens: tokens))
    }

    private func intern(_ value: String, _ last: inout String) -> String {
        if value != last { last = value }
        return last
    }

    private struct Line: Decodable {
        let step_index: Int?
        let type: String?
        let created_at: String?
        let model: String?
        let input_tokens: Int?
        let cache_read_tokens: Int?
        let cache_creation_tokens: Int?
        let output_tokens: Int?
    }
}
