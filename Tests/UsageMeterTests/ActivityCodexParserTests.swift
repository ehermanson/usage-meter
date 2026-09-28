import Foundation
import Testing

@testable import UsageMeter

/// Codex rollout line builders — the `{timestamp, type, payload}` envelope.
enum CodexLine {
    static func line(_ type: String, _ payload: [String: Any], at timestamp: String) -> String {
        let object: [String: Any] = ["timestamp": timestamp, "type": type, "payload": payload]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static func usage(
        input: Int, cached: Int = 0, cacheWrite: Int = 0, output: Int = 0, reasoning: Int = 0
    ) -> [String: Any] {
        [
            "input_tokens": input, "cached_input_tokens": cached,
            "cache_write_input_tokens": cacheWrite, "output_tokens": output,
            "reasoning_output_tokens": reasoning, "total_tokens": input + output,
        ]
    }

    static func meta(
        id: String, session: String? = nil, forkedFrom: String? = nil,
        parentThread: String? = nil, at t: String = "2026-09-27T13:19:53.960Z"
    ) -> String {
        var payload: [String: Any] = ["id": id, "base_instructions": ["text": "long…"]]
        if let session { payload["session_id"] = session }
        if let forkedFrom { payload["forked_from_id"] = forkedFrom }
        if let parentThread { payload["parent_thread_id"] = parentThread }
        return line("session_meta", payload, at: t)
    }

    static func turn(
        model: String, id: String? = nil, at t: String = "2026-09-27T13:19:55.000Z"
    ) -> String {
        var payload: [String: Any] = ["model": model, "cwd": "/tmp"]
        if let id { payload["turn_id"] = id }
        return line("turn_context", payload, at: t)
    }

    /// A token_count whose total and last usage are both `input` fresh
    /// tokens plus `output` — enough for tests that follow the running total.
    static func total(_ input: Int, output: Int = 0, last: Int? = nil, at t: String) -> String {
        tokenCount(
            total: usage(input: input, output: output),
            last: usage(input: last ?? input, output: 0), at: t)
    }

    static func tokenCount(total: [String: Any]?, last: [String: Any]?, at t: String) -> String {
        guard let total, let last else {
            return line("event_msg", ["type": "token_count", "info": NSNull()], at: t)
        }
        return line(
            "event_msg",
            [
                "type": "token_count",
                "info": ["total_token_usage": total, "last_token_usage": last],
            ], at: t)
    }

    static func record(response: String, _ usage: [String: Any], at t: String) -> String {
        line("token_usage_record", ["response_id": response, "usage": usage], at: t)
    }
}

/// Rollouts modelled on real files, for the parser and scanner tests.
enum CodexFixture {
    typealias L = CodexLine

    /// rollout-2026-08-14T12-41-43-01a00126…: CLI 0.148 wrote only
    /// token_count for days…
    static let mixedOldCLI = [
        L.meta(id: "01a00126-9dbb-7980-aef6-f050bb8a82d4", at: "2026-08-14T16:41:43.000Z"),
        L.turn(model: "gpt-5.6-sol", at: "2026-08-14T16:41:44.000Z"),
        L.total(1_000_000, at: "2026-08-14T16:42:00.000Z"),
        L.total(1_000_000, at: "2026-08-14T16:42:00.500Z"),  // repeat
        L.total(16_671_705, last: 15_671_705, at: "2026-08-18T20:03:44.010Z"),
    ]
    /// …then a newer CLI resumed it weeks later, writing a record ahead of
    /// each token_count, whose running total carries on from the old part's.
    static let mixedResumed = [
        L.turn(model: "gpt-5.6-sol", at: "2026-09-04T18:00:41.295Z"),
        L.record(
            response: "resp_1", L.usage(input: 93_000, cached: 80_000, output: 813),
            at: "2026-09-04T18:00:49.611Z"),
        L.tokenCount(
            total: L.usage(input: 16_764_705, cached: 80_000, output: 813),
            last: L.usage(input: 93_000, cached: 80_000, output: 813),
            at: "2026-09-04T18:00:50.309Z"),
        L.record(
            response: "resp_2", L.usage(input: 99_000, cached: 90_000, output: 648),
            at: "2026-09-04T18:01:00.396Z"),
        L.tokenCount(
            total: L.usage(input: 16_863_705, cached: 170_000, output: 1461),
            last: L.usage(input: 99_000, cached: 90_000, output: 648),
            at: "2026-09-04T18:01:00.397Z"),
    ]
    /// Two token_count deltas from the old part, then the two records.
    static let mixedTotals = [1_000_000, 15_671_705, 93_813, 99_648]
    static let mixedFinalTotal = 16_863_705 + 1461

    /// A fork written by CLI 0.145.0, modelled on
    /// rollout-2026-07-25T20-18-28-019f9bc9-9822-…: its meta, the parent's
    /// replayed turns and token_counts (all stamped within a few ms of the
    /// fork, turn ids from the parent's time)…
    static let forkId = "019f9bc9-9822-7063-b950-38082c954c2d"  // 00:18:28.002
    static let parentId = "019f7597-96f4-7152-b63b-d064ca364d9f"
    static let forkReplay = [
        L.meta(
            id: forkId, session: parentId, forkedFrom: parentId, parentThread: parentId,
            at: "2026-07-26T00:18:28.192Z"),
        L.turn(
            model: "gpt-5.6-sol", id: "019f7597-99ce-7631-a305-14318c0b976a",
            at: "2026-07-26T00:18:28.192Z"),
        L.total(22_232, at: "2026-07-26T00:18:28.192Z"),
        L.total(44_853, last: 22_621, at: "2026-07-26T00:18:28.193Z"),
        L.turn(
            model: "gpt-5.6-sol", id: "019f7a10-1111-7222-8333-444455556666",
            at: "2026-07-26T00:18:28.199Z"),
        L.total(22_366_595, last: 212_763, at: "2026-07-26T00:18:28.200Z"),
    ]
    /// …then the fork's own turn (a turn id newer than the fork's) and real
    /// responses seconds later, measured from where the replay left the total.
    static let forkOwnTurn = [
        L.turn(
            model: "gpt-5.6-terra", id: "019f9bc9-98ee-73a1-b20a-6aa8e550dde0",
            at: "2026-07-26T00:18:29.825Z"),
        L.total(22_403_985, last: 37_390, at: "2026-07-26T00:18:38.713Z"),
        L.total(22_403_985, last: 37_390, at: "2026-07-26T00:18:38.800Z"),  // repeat
        L.total(22_441_853, last: 37_868, at: "2026-07-26T00:18:42.817Z"),
    ]
    static let forkOwnTotals = [37_390, 37_868]

    /// A thread rolled back twice on CLI 0.115, its token_count events as
    /// rollout-2026-04-13T20-58-30-019d897f-… logged them (lines 103, 110,
    /// 140, 147, 155, 800, 806, 810, 816). Each rollback's next turn opens by
    /// re-emitting the restored turn's event whole, a drop in the total that
    /// isn't a reset.
    static let rollback: [String] = {
        // Totals that are logged more than once, each with its last response.
        let first = L.usage(input: 372_077, cached: 299_648, output: 4682, reasoning: 1037)
        let firstLast = L.usage(input: 45_213, cached: 45_056, output: 536)
        let third = L.usage(input: 578_283, cached: 457_088, output: 5798, reasoning: 1096)
        let thirdLast = L.usage(input: 52_634, cached: 52_480, output: 348)
        let final = L.usage(input: 633_142, cached: 460_544, output: 5958, reasoning: 1117)
        let finalLast = L.usage(input: 54_859, cached: 3456, output: 160, reasoning: 21)
        return [
            L.meta(id: "019d897f-3e61-7ac1-b4e7-7123410b3bbb", at: "2026-04-14T00:58:30.000Z"),
            L.turn(model: "gpt-5.4", at: "2026-04-14T02:30:00.000Z"),
            L.tokenCount(total: first, last: firstLast, at: "2026-04-14T02:35:54.898Z"),
            // The next turn's start repeats it.
            L.tokenCount(total: first, last: firstLast, at: "2026-04-14T18:00:28.114Z"),
            L.tokenCount(total: third, last: thirdLast, at: "2026-04-14T18:00:55.943Z"),
            // Rolled back to the first state: its event again, not a reset.
            L.tokenCount(total: first, last: firstLast, at: "2026-04-14T18:05:17.176Z"),
            L.tokenCount(
                total: L.usage(input: 420_197, cached: 303_104, output: 5110, reasoning: 1100),
                last: L.usage(input: 48_120, cached: 3456, output: 428, reasoning: 63),
                at: "2026-04-14T18:05:26.640Z"),
            L.tokenCount(
                total: L.usage(
                    input: 8_436_138, cached: 7_176_704, output: 39_470, reasoning: 6420),
                last: L.usage(input: 189_510, cached: 188_928, output: 441),
                at: "2026-04-14T19:16:50.426Z"),
            // Restored to the third state.
            L.tokenCount(total: third, last: thirdLast, at: "2026-04-14T19:22:55.276Z"),
            L.tokenCount(total: final, last: finalLast, at: "2026-04-14T19:23:00.461Z"),
            L.tokenCount(total: final, last: finalLast, at: "2026-04-14T19:23:17.366Z"),
        ]
    }()
    /// The first event in full, then each move of the total. Counting a
    /// restore's last response instead would add 45,749 and 52,982 again.
    static let rollbackTotals = [376_759, 207_322, 48_548, 8_050_301, 55_019]
}

private func parse(
    _ lines: [String], fallback: String = "file-uuid", until cutoff: Date? = nil
) -> [UsageRecord] {
    let parser = CodexLogParser(fallbackSessionId: fallback, until: cutoff)
    let decoder = JSONDecoder()
    for line in lines { parser.consume(Data(line.utf8), decoder: decoder) }
    return parser.records
}

@Suite("Codex log parsing")
struct ActivityCodexParserTests {
    typealias L = CodexLine
    typealias F = CodexFixture

    @Test("usage records are preferred over token_count events in the same file")
    func prefersUsageRecords() {
        let u1 = L.usage(input: 21_303, output: 106)
        let u2 = L.usage(input: 32_653, cached: 21_120, output: 79)
        let records = parse([
            L.meta(id: "thread-1"),
            L.turn(model: "gpt-6-astra"),
            L.record(response: "resp_a", u1, at: "2026-09-27T13:20:00.786Z"),
            L.tokenCount(total: u1, last: u1, at: "2026-09-27T13:20:01.189Z"),
            L.record(response: "resp_b", u2, at: "2026-09-27T13:20:06.000Z"),
            L.tokenCount(
                total: L.usage(input: 53_956, cached: 21_120, output: 185), last: u2,
                at: "2026-09-27T13:20:06.624Z"),
        ])
        #expect(records.map(\.dedupeKey) == ["resp_a", "resp_b"])
        #expect(records.map(\.tokens.total) == [21_409, 32_732])
    }

    @Test("token_count counts until the file's first usage record, and not after it")
    func switchesToUsageRecordsMidFile() {
        let u = L.usage(input: 1000, output: 10)
        let records = parse([
            L.tokenCount(total: u, last: u, at: "2026-09-27T13:20:00Z"),
            L.record(response: "resp_a", u, at: "2026-09-27T13:20:01Z"),
            L.tokenCount(
                total: L.usage(input: 2010, output: 20), last: u, at: "2026-09-27T13:20:02Z"),
        ])
        #expect(records.map(\.dedupeKey) == [nil, "resp_a"])
        #expect(records.map(\.tokens.total) == [1010, 1010])

        // Even a record with nothing in it marks where the newer CLI took over.
        let empty = parse([
            L.tokenCount(total: u, last: u, at: "2026-09-27T13:20:00Z"),
            L.record(response: "resp_0", L.usage(input: 0), at: "2026-09-27T13:20:01Z"),
            L.tokenCount(
                total: L.usage(input: 3000, output: 30), last: u, at: "2026-09-27T13:20:02Z"),
        ])
        #expect(empty.map(\.tokens.total) == [1010])
    }

    @Test("a session begun on an old CLI and resumed on a new one counts both parts once")
    func mixedFormatFile() {
        let records = parse(F.mixedOldCLI + F.mixedResumed)
        #expect(records.map(\.dedupeKey) == [nil, nil, "resp_1", "resp_2"])
        #expect(records.map(\.tokens.total) == F.mixedTotals)
        let stamps = [
            "2026-08-14T16:42:00.000Z", "2026-08-18T20:03:44.010Z",
            "2026-09-04T18:00:49.611Z", "2026-09-04T18:01:00.396Z",
        ]
        #expect(records.map(\.timestamp) == stamps.compactMap { Parse.isoDate($0) })
        // Everything the thread's final running total says, exactly once.
        #expect(records.reduce(0) { $0 + $1.tokens.total } == F.mixedFinalTotal)
    }

    @Test("a fork's replay of its parent's token_counts sets the baseline and counts nothing")
    func forkReplayNotCounted() {
        let records = parse(F.forkReplay + F.forkOwnTurn)
        #expect(records.map(\.tokens.total) == F.forkOwnTotals)
        #expect(records.allSatisfy { $0.model == "gpt-5.6-terra" })
        #expect(records.allSatisfy { $0.sessionId == F.parentId })
        #expect(records.first?.timestamp == Parse.isoDate("2026-07-26T00:18:38.713Z"))

        // A fork never used past its replay adds nothing at all.
        #expect(parse(F.forkReplay).isEmpty)

        // The parent's meta, repeated after the fork's, changes nothing.
        let repeatedMeta = L.meta(id: F.parentId, session: F.parentId)
        let withParentMeta = parse(
            [F.forkReplay[0], repeatedMeta] + F.forkReplay.dropFirst() + F.forkOwnTurn)
        #expect(withParentMeta.map(\.tokens.total) == F.forkOwnTotals)
    }

    @Test("the replay ends at the fork's own turn even when written more than a second late")
    func slowReplayStillSkipped() {
        // Replayed events stamped 3 s after the meta: the turn ids still say
        // they're the parent's.
        let records = parse([
            L.meta(id: F.forkId, forkedFrom: F.parentId, at: "2026-07-26T00:18:28.192Z"),
            L.turn(
                model: "gpt-5.6-sol", id: "019f7597-99ce-7631-a305-14318c0b976a",
                at: "2026-07-26T00:18:31.000Z"),
            L.total(500_000, at: "2026-07-26T00:18:31.500Z"),
            L.turn(
                model: "gpt-5.6-terra", id: "019f9bc9-98ee-73a1-b20a-6aa8e550dde0",
                at: "2026-07-26T00:18:32.000Z"),
            L.total(500_100, last: 100, at: "2026-07-26T00:18:40.000Z"),
        ])
        #expect(records.map(\.tokens.total) == [100])
    }

    @Test("without UUIDv7 ids, events within a second of the fork's meta are the replay")
    func forkReplayByTime() {
        let fork = "5f0c2a8e-3b1d-4c2e-9a7f-0e1d2c3b4a59"  // version 4: no time in it
        let records = parse([
            L.meta(id: fork, forkedFrom: "parent", at: "2026-03-18T00:41:24.592Z"),
            L.turn(model: "gpt-5.4", at: "2026-03-18T00:41:24.594Z"),
            L.total(14_340, at: "2026-03-18T00:41:24.594Z"),
            L.total(28_909, last: 14_569, at: "2026-03-18T00:41:24.900Z"),
            L.turn(model: "gpt-5.4", at: "2026-03-18T00:43:24.724Z"),
            L.total(40_000, last: 11_091, at: "2026-03-18T00:43:30.000Z"),
        ])
        #expect(records.map(\.tokens.total) == [11_091])

        // A v7 thread whose turn_context has no turn_id falls back the same way.
        let noTurnIds = parse([
            L.meta(id: F.forkId, forkedFrom: F.parentId, at: "2026-07-26T00:18:28.192Z"),
            L.turn(model: "gpt-5.6-sol", at: "2026-07-26T00:18:28.193Z"),
            L.total(22_232, at: "2026-07-26T00:18:28.194Z"),
            L.turn(model: "gpt-5.6-terra", at: "2026-07-26T00:18:29.825Z"),
            L.total(30_000, last: 7_768, at: "2026-07-26T00:18:38.713Z"),
        ])
        #expect(noTurnIds.map(\.tokens.total) == [7_768])
    }

    @Test("threads that aren't forks count from their first event")
    func childThreadsCountFromTheStart() {
        // A sub-agent thread names its parent but replays nothing, and its
        // first turn can come within the second.
        let records = parse([
            L.meta(
                id: "01a0b528-089a-7000-8000-000000000001", session: "root",
                parentThread: "01a0b527-0000-7000-8000-000000000000",
                at: "2026-09-18T15:34:54.000Z"),
            L.turn(
                model: "gpt-5.6-sol", id: "01a0b528-0000-7000-8000-000000000002",
                at: "2026-09-18T15:34:54.100Z"),
            L.total(30_000, at: "2026-09-18T15:34:54.500Z"),
        ])
        #expect(records.map(\.tokens.total) == [30_000])
    }

    @Test("a cutoff reads the file as it stood then")
    func cutoff() throws {
        // Before the resume, the old CLI's deltas are all there is.
        let beforeResume = try #require(Parse.isoDate("2026-09-01T00:00:00Z"))
        #expect(
            parse(F.mixedOldCLI + F.mixedResumed, until: beforeResume).map(\.tokens.total)
                == Array(F.mixedTotals.prefix(2)))
        // Mid-replay, a fork has counted nothing yet; just after its first
        // response, one delta from the replay's baseline.
        let midReplay = try #require(Parse.isoDate("2026-07-26T00:18:28.193Z"))
        #expect(parse(F.forkReplay + F.forkOwnTurn, until: midReplay).isEmpty)
        let afterFirst = try #require(Parse.isoDate("2026-07-26T00:18:40Z"))
        #expect(
            parse(F.forkReplay + F.forkOwnTurn, until: afterFirst).map(\.tokens.total)
                == [F.forkOwnTotals[0]])
    }

    @Test("UUIDv7 ids decode to their millisecond stamp; anything else is nil")
    func uuidV7Millis() throws {
        #expect(CodexLogParser.uuidV7Millis(F.forkId) == 0x019f_9bc9_9822)
        #expect(
            CodexLogParser.uuidV7Millis("019F9BC9-9822-7063-B950-38082C954C2D") == 0x019f_9bc9_9822)
        let millis = try #require(CodexLogParser.uuidV7Millis(F.forkId))
        let created = try #require(Parse.isoDate("2026-07-26T00:18:28.002Z"))
        #expect(abs(Double(millis) / 1000 - created.timeIntervalSince1970) < 0.000_5)
        #expect(CodexLogParser.uuidV7Millis("5f0c2a8e-3b1d-4c2e-9a7f-0e1d2c3b4a59") == nil)
        #expect(CodexLogParser.uuidV7Millis("019f9bc9982270630b95038082c954c2d") == nil)
        #expect(CodexLogParser.uuidV7Millis("019f9bc9-98zz-7063-b950-38082c954c2d") == nil)
        #expect(CodexLogParser.uuidV7Millis(nil) == nil)
    }

    @Test("token_count deltas: repeats skipped, first counts in full, resets use last usage")
    func tokenCountDeltas() {
        let first = L.usage(input: 100, cached: 40, output: 10)
        let second = L.usage(input: 250, cached: 140, output: 30)
        let afterReset = L.usage(input: 50, cached: 0, output: 5)
        let records = parse([
            L.turn(model: "gpt-5.5"),
            L.tokenCount(total: first, last: first, at: "2026-09-27T10:00:00Z"),
            L.tokenCount(total: first, last: first, at: "2026-09-27T10:00:01Z"),  // repeat
            L.tokenCount(total: nil, last: nil, at: "2026-09-27T10:00:02Z"),  // info: null
            L.tokenCount(
                total: second, last: L.usage(input: 150, cached: 100, output: 20),
                at: "2026-09-27T10:00:03Z"),
            L.tokenCount(total: second, last: second, at: "2026-09-27T10:00:04Z"),  // repeat
            // The running total went down: a reset. Its own last usage counts.
            L.tokenCount(total: afterReset, last: afterReset, at: "2026-09-27T10:00:05Z"),
        ])
        #expect(
            records.map(\.tokens) == [
                TokenCounts(input: 60, output: 10, cacheRead: 40, cacheWrite: 0),
                TokenCounts(input: 50, output: 20, cacheRead: 100, cacheWrite: 0),
                TokenCounts(input: 50, output: 5, cacheRead: 0, cacheWrite: 0),
            ])
        #expect(records.allSatisfy { $0.dedupeKey == nil })
        // The totals the events carried: 110, then 280, then a reset to 55.
        #expect(records.map(\.tokens.total) == [110, 170, 55])
    }

    @Test("a rollback's re-emitted total moves the baseline and counts nothing")
    func rollbackRestore() {
        let records = parse(F.rollback)
        #expect(records.map(\.tokens.total) == F.rollbackTotals)
        // Every branch's work once: 584,081 up to the first rollback, then
        // 8,098,849 on from the state it restored, then 55,019 after the
        // second.
        let counted: Int = records.map(\.tokens.total).reduce(0, +)
        #expect(counted == 8_737_949)

        // A drop to a total the file hasn't reported is still a reset.
        let reset = parse(
            F.rollback + [
                L.tokenCount(
                    total: L.usage(input: 57_000, output: 374),
                    last: L.usage(input: 57_000, output: 374), at: "2026-04-14T20:00:00.000Z")
            ])
        #expect(reset.map(\.tokens.total) == F.rollbackTotals + [57_374])
    }

    @Test("input is split into uncached input, cache reads and cache writes")
    func normalizesOpenAIUsage() throws {
        let record = try #require(
            parse([
                L.record(
                    response: "r", L.usage(input: 1000, cached: 600, cacheWrite: 300, output: 50),
                    at: "2026-09-27T10:00:00Z")
            ]).first)
        #expect(
            record.tokens == TokenCounts(input: 100, output: 50, cacheRead: 600, cacheWrite: 300))
        #expect(record.tokens.total == 1050)  // = total_tokens
    }

    @Test("the model comes from the latest turn_context")
    func modelFromTurnContext() {
        let u = L.usage(input: 10, output: 1)
        let records = parse([
            L.record(response: "r0", u, at: "2026-09-27T10:00:00Z"),
            L.turn(model: "gpt-6-astra"),
            L.record(response: "r1", u, at: "2026-09-27T10:00:01Z"),
            L.turn(model: "gpt-5.6-sol"),
            L.record(response: "r2", u, at: "2026-09-27T10:00:02Z"),
        ])
        #expect(records.map(\.model) == ["unknown", "gpt-6-astra", "gpt-5.6-sol"])
    }

    @Test("session: session_id, else id, from the first session_meta; else the file name")
    func sessionResolution() {
        let u = L.usage(input: 10, output: 1)
        let rec = L.record(response: "r", u, at: "2026-09-27T10:00:00Z")
        // A child thread names its root session; a forked file then repeats
        // the parent's meta, which mustn't override it.
        let child = parse([
            L.meta(id: "child-thread", session: "root-session"),
            L.meta(id: "parent-thread", session: "parent-session"), rec,
        ])
        #expect(child.first?.sessionId == "root-session")
        #expect(parse([L.meta(id: "old-thread"), rec]).first?.sessionId == "old-thread")
        #expect(parse([rec], fallback: "from-file").first?.sessionId == "from-file")

        let file = URL(
            fileURLWithPath:
                "/x/sessions/2026/09/27/rollout-2026-09-27T09-19-53-01a0e305-a6b0-7b70-bced-efadaef99fde.jsonl"
        )
        #expect(CodexLogSource.sessionId(forFile: file) == "01a0e305-a6b0-7b70-bced-efadaef99fde")
    }

    @Test("response ids dedupe usage records across files")
    func responseIdDedupe() {
        let u = L.usage(input: 500, output: 5)
        let a = parse([L.record(response: "resp_x", u, at: "2026-09-27T10:00:00Z")])
        let b = parse([
            L.record(response: "resp_x", u, at: "2026-09-27T11:00:00Z"),
            L.record(response: "resp_y", u, at: "2026-09-27T11:00:01Z"),
        ])
        let kept = ActivityAggregator.dedupe(a + b)
        #expect(kept.count == 2)
        #expect(kept.first?.timestamp == Parse.isoDate("2026-09-27T10:00:00Z"))
    }

    @Test("CODEX_HOME overrides ~/.codex")
    func codexHome() {
        let custom = FileManager.default.temporaryDirectory.appendingPathComponent("codex-x")
        #expect(
            CodexLogSource.home(environment: ["CODEX_HOME": custom.path], home: "/nowhere").path
                == custom.resolvingSymlinksInPath().standardizedFileURL.path)
        #expect(CodexLogSource.home(environment: [:], home: "/nowhere").path == "/nowhere/.codex")
    }
}
