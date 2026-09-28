import Foundation
import Testing

@testable import UsageMeter

/// Builds one Claude Code transcript line. Only the fields the parser reads,
/// plus some content, since real lines carry the message body too.
func claudeLine(
    type: String = "assistant", id: String? = "msg_1", request: String? = "req_1",
    model: String = "claude-opus-5-5", timestamp: String = "2026-09-21T23:24:31.784Z",
    session: String? = "session-a", input: Int = 2, output: Int = 100, cacheRead: Int = 0,
    cacheWrite: Int = 0, oneHour: Int? = nil, speed: String? = "standard"
) -> String {
    var usage: [String: Any] = [
        "input_tokens": input, "output_tokens": output, "cache_read_input_tokens": cacheRead,
        "cache_creation_input_tokens": cacheWrite,
    ]
    if let oneHour {
        usage["cache_creation"] = [
            "ephemeral_1h_input_tokens": oneHour, "ephemeral_5m_input_tokens": cacheWrite - oneHour,
        ]
    }
    if let speed { usage["speed"] = speed }
    var message: [String: Any] = [
        "model": model, "role": "assistant", "usage": usage,
        "content": [["type": "text", "text": "Some \"quoted\" usage text"]],
    ]
    if let id { message["id"] = id }
    var line: [String: Any] = ["type": type, "timestamp": timestamp, "message": message]
    if let request { line["requestId"] = request }
    if let session { line["sessionId"] = session }
    let data = try! JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

private func parse(
    _ lines: [String], fallback: String = "file-session", until cutoff: Date? = nil
) -> [UsageRecord] {
    let parser = ClaudeLogParser(fallbackSessionId: fallback, until: cutoff)
    let decoder = JSONDecoder()
    for line in lines { parser.consume(Data(line.utf8), decoder: decoder) }
    return parser.records
}

@Suite("Claude Code log parsing")
struct ActivityClaudeParserTests {
    @Test("an assistant line becomes a record with normalized counts")
    func parsesAssistantUsage() throws {
        let records = parse([
            claudeLine(input: 3, output: 114, cacheRead: 24_866, cacheWrite: 23_732)
        ])
        let record = try #require(records.first)
        #expect(records.count == 1)
        #expect(record.provider == "Claude")
        #expect(record.model == "claude-opus-5-5")
        #expect(record.sessionId == "session-a")
        #expect(record.dedupeKey == "msg_1:req_1")
        #expect(
            record.tokens
                == TokenCounts(input: 3, output: 114, cacheRead: 24_866, cacheWrite: 23_732))
        #expect(record.timestamp == Parse.isoDate("2026-09-21T23:24:31.784Z"))
        #expect(!record.fast)
    }

    @Test("one line per content block folds into one record with the final output count")
    func foldsContentBlockDuplicates() throws {
        // Real shape: the first block's line is written mid-stream with a
        // partial output count; the later block's line has the final one.
        let records = parse([
            claudeLine(timestamp: "2026-09-27T23:41:44.857Z", output: 8, cacheRead: 205_765),
            claudeLine(timestamp: "2026-09-27T23:41:46.100Z", output: 4355, cacheRead: 205_765),
        ])
        let record = try #require(records.first)
        #expect(records.count == 1)
        #expect(record.tokens.output == 4355)
        #expect(record.tokens.cacheRead == 205_765)
        #expect(record.timestamp == Parse.isoDate("2026-09-27T23:41:44.857Z"))
    }

    @Test("lines missing message.id or requestId are never merged")
    func missingIdsAreNotDeduped() {
        let records = parse([
            claudeLine(id: nil, output: 10),
            claudeLine(id: nil, output: 10),
            claudeLine(request: nil, output: 10),
            claudeLine(id: "", request: "req_1", output: 10),
        ])
        #expect(records.count == 4)
        #expect(records.allSatisfy { $0.dedupeKey == nil })
    }

    @Test("synthetic placeholders, zero-token lines and non-assistant lines are skipped")
    func skipsNonBillable() {
        let userLine = #"{"type":"user","message":{"role":"user","usage":{"input_tokens":5}}}"#
        let records = parse([
            claudeLine(model: "<synthetic>", output: 50),
            claudeLine(id: "msg_2", input: 0, output: 0),
            userLine,
            "not json at all \"usage\"",
            claudeLine(id: "msg_3", output: 1),
        ])
        #expect(records.map(\.dedupeKey) == ["msg_3:req_1"])
    }

    @Test("the 1h cache write is kept as a subset of the cache write total")
    func splitsOneHourCacheWrites() throws {
        let record = try #require(parse([claudeLine(cacheWrite: 1000, oneHour: 600)]).first)
        #expect(record.tokens.cacheWrite == 1000)
        #expect(record.cacheWrite1h == 600)
        // A malformed 1h figure larger than the total can't exceed it…
        let clamped = try #require(parse([claudeLine(cacheWrite: 100, oneHour: 900)]).first)
        #expect(clamped.cacheWrite1h == 100)
        // …nor go below zero.
        let negative = try #require(parse([claudeLine(cacheWrite: 100, oneHour: -5)]).first)
        #expect(negative.cacheWrite1h == 0)
    }

    @Test("fast mode is read from usage.speed")
    func readsFastMode() throws {
        let record = try #require(parse([claudeLine(speed: "fast")]).first)
        #expect(record.fast)
    }

    @Test("a zero copy is dropped before merging, so it can't stand in for the response")
    func zeroCopyDroppedBeforeMerge() throws {
        // Real shape (ghin-plus 3c652003…, lines 1595/1596 and 4709/4710):
        // stray copies with all four counts zero but a 1h figure, sharing the
        // real response's key and (to the millisecond) its timestamps.
        let real = { (t: String) in
            claudeLine(
                id: "msg_011Ced569b", request: "req_011Ced564v", timestamp: t, input: 56,
                output: 709, cacheRead: 491_973, cacheWrite: 523, oneHour: 0)
        }
        let zero = { (t: String) in
            claudeLine(
                id: "msg_011Ced569b", request: "req_011Ced564v", timestamp: t, input: 0,
                output: 0, cacheRead: 0, cacheWrite: 0, oneHour: 523, speed: nil)
        }
        let first = "2026-09-20T16:56:08.354Z"
        let second = "2026-09-20T16:56:08.380Z"
        for lines in [
            [real(first), real(second), zero(first), zero(second)],
            [zero(first), zero(second), real(first), real(second)],
        ] {
            let records = parse(lines)
            let record = try #require(records.first)
            #expect(records.count == 1)
            #expect(
                record.tokens
                    == TokenCounts(input: 56, output: 709, cacheRead: 491_973, cacheWrite: 523))
            // The zero copy's 523 would have made the whole write 1h.
            #expect(record.cacheWrite1h == 0)
            #expect(record.timestamp == Parse.isoDate(first))
        }
    }

    @Test("copies merge: largest counts, fast if any copy is, earliest time, final model")
    func mergesCopies() throws {
        // The mid-stream copy has a partial output count and no speed; the
        // final one says fast. Either order, the merge is the same.
        let partial = claudeLine(
            model: "claude-opus-5-5", timestamp: "2026-09-27T23:41:15.000Z", output: 8,
            cacheRead: 205_765, speed: nil)
        let final = claudeLine(
            model: "claude-opus-5-5", timestamp: "2026-09-27T23:41:44.000Z", output: 4355,
            cacheRead: 205_765, speed: "fast")
        for lines in [[partial, final], [final, partial]] {
            let record = try #require(parse(lines).first)
            #expect(parse(lines).count == 1)
            #expect(record.tokens.output == 4355)
            #expect(record.fast)
            #expect(record.timestamp == Parse.isoDate("2026-09-27T23:41:15.000Z"))
        }

        // The model is the largest-output copy's, the timestamp the earliest.
        let early = try #require(
            parse([claudeLine(model: "early-model", timestamp: "2026-09-27T10:00:00Z", output: 8)])
                .first)
        let late = try #require(
            parse([claudeLine(model: "final-model", timestamp: "2026-09-27T10:00:05Z", output: 90)])
                .first)
        for merged in [early.merged(with: late), late.merged(with: early)] {
            #expect(merged.model == "final-model")
            #expect(merged.timestamp == early.timestamp)
            #expect(merged.tokens.output == 90)
        }
    }

    @Test("a cutoff ignores lines stamped after it, before copies merge")
    func cutoffBeforeMerge() throws {
        let partial = claudeLine(timestamp: "2026-09-27T23:41:15.000Z", output: 8, speed: nil)
        let final = claudeLine(timestamp: "2026-09-27T23:41:44.000Z", output: 4355)
        let later = claudeLine(id: "msg_2", timestamp: "2026-09-27T23:50:00.000Z")
        let cut = try #require(Parse.isoDate("2026-09-27T23:41:30Z"))
        // As the log stood at 23:41:30: only the mid-stream copy was written.
        let records = parse([partial, final, later], until: cut)
        #expect(records.map(\.tokens.output) == [8])
        #expect(parse([partial, final, later]).map(\.tokens.output) == [4355, 100])
        // A line stamped exactly at the cutoff is in.
        let exact = try #require(Parse.isoDate("2026-09-27T23:41:44.000Z"))
        #expect(parse([partial, final, later], until: exact).map(\.tokens.output) == [4355])
    }

    @Test("the 1h write merges as the largest logged figure, then clamps to the merged write")
    func mergesOneHourThenClamps() throws {
        let a = try #require(parse([claudeLine(output: 5, cacheWrite: 100, oneHour: 500)]).first)
        let b = try #require(parse([claudeLine(output: 9, cacheWrite: 600, oneHour: 0)]).first)
        #expect(a.cacheWrite1h == 100)  // alone, clamped to its own write
        // Merged: max(500, 0) = 500, within the merged write of 600. Clamping
        // each copy first would have given 100.
        #expect(a.merged(with: b).cacheWrite1h == 500)
        #expect(b.merged(with: a).cacheWrite1h == 500)
        let c = try #require(parse([claudeLine(output: 9, cacheWrite: 300, oneHour: 0)]).first)
        #expect(a.merged(with: c).cacheWrite1h == 300)  // max 500, clamped to 300
    }

    @Test("a subagent transcript counts toward its parent's session")
    func subagentSession() {
        // The line's own sessionId is the parent's…
        let records = parse([claudeLine(session: "parent-uuid")], fallback: "agent-abc")
        #expect(records.first?.sessionId == "parent-uuid")

        // …and without one, the file's location names the parent too.
        let subagent = URL(
            fileURLWithPath: "/x/projects/-proj/parent-uuid/subagents/agent-abc.jsonl")
        #expect(ClaudeLogSource.sessionId(forFile: subagent) == "parent-uuid")
        let transcript = URL(fileURLWithPath: "/x/projects/-proj/session-uuid.jsonl")
        #expect(ClaudeLogSource.sessionId(forFile: transcript) == "session-uuid")
        let orphan = parse([claudeLine(session: nil)], fallback: "session-uuid")
        #expect(orphan.first?.sessionId == "session-uuid")
    }

    @Test("config dirs: override, each CLAUDE_CONFIG_DIR entry, defaults — deduped, existing only")
    func configDirs() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("claude-home-\(UUID().uuidString)")
        let custom = home.appendingPathComponent("custom")
        let work = home.appendingPathComponent("work")
        for dir in [custom, work, home.appendingPathComponent(".claude")] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: home) }
        // A symlink to a dir already listed must not add it twice.
        let link = home.appendingPathComponent("link-to-work")
        try fm.createSymbolicLink(at: link, withDestinationURL: work)

        let dirs = ClaudeLogSource.configDirs(
            override: custom.path,
            environment: ["CLAUDE_CONFIG_DIR": "\(work.path), \(link.path),\(home.path)/missing"],
            detected: nil, home: home.path)
        let expected = [custom, work, home.appendingPathComponent(".claude")].map {
            $0.resolvingSymlinksInPath().standardizedFileURL.path
        }
        #expect(dirs.map(\.path) == expected)
    }

    @Test("config dirs: the helper's detected dir comes after the env, before the defaults")
    func configDirsWithDetected() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("claude-home-\(UUID().uuidString)")
        let custom = home.appendingPathComponent("custom")
        let work = home.appendingPathComponent("work")
        // Exported only in ~/.profile, where the helper's login shell finds
        // it: the app's own env never has it.
        let shell = home.appendingPathComponent("from-shell")
        let dot = home.appendingPathComponent(".claude")
        let xdg = home.appendingPathComponent(".config/claude")
        for dir in [custom, work, shell, dot, xdg] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: home) }
        func paths(_ urls: [URL]) -> [String] {
            urls.map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
        }

        let all = ClaudeLogSource.configDirs(
            override: custom.path, environment: ["CLAUDE_CONFIG_DIR": work.path],
            detected: shell.path, home: home.path)
        #expect(paths(all) == paths([custom, work, shell, dot, xdg]))

        // No override or env, as for an app launched from the Dock.
        let gui = ClaudeLogSource.configDirs(
            override: nil, environment: [:], detected: shell.path, home: home.path)
        #expect(paths(gui) == paths([shell, dot, xdg]))

        // Another spelling of a dir already listed isn't listed twice, and
        // one that's gone is skipped.
        let respelled = ClaudeLogSource.configDirs(
            override: nil, environment: [:], detected: "\(home.path)/work/../.claude",
            home: home.path)
        #expect(paths(respelled) == paths([dot, xdg]))
        let missing = ClaudeLogSource.configDirs(
            override: nil, environment: [:], detected: "\(home.path)/deleted", home: home.path)
        #expect(paths(missing) == paths([dot, xdg]))
    }

    @Test("CLAUDE_CONFIG_DIR: a dir with a comma in its name is one entry, a list is split")
    func configDirWithComma() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("claude-home-\(UUID().uuidString)")
        let comma = home.appendingPathComponent("work,old")
        let work = home.appendingPathComponent("work")
        let other = home.appendingPathComponent("other")
        for dir in [comma, work, other] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: home) }
        func dirs(_ env: String) -> [String] {
            ClaudeLogSource.configDirs(
                override: nil, environment: ["CLAUDE_CONFIG_DIR": env], detected: nil,
                home: home.path
            ).map(\.path)
        }
        func path(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }

        // Split, it would be `…/work` (which exists) and `old`.
        #expect(dirs(comma.path) == [path(comma)])
        #expect(ClaudeLogSource.entries(of: comma.path) == [comma.path])
        // Not a directory as a whole: a list.
        #expect(dirs("\(work.path), \(other.path)") == [path(work), path(other)])
        #expect(ClaudeLogSource.entries(of: "") == [])
        #expect(ClaudeLogSource.entries(of: " , ") == [])
    }

    @Test("fast timestamp parsing agrees with the ISO formatter")
    func timestamps() {
        for sample in [
            "2026-09-21T23:24:31.784Z", "2026-09-21T23:24:31Z", "2024-02-29T00:00:00.5Z",
            "1999-12-31T23:59:59.999Z", "2026-09-21T19:24:31.784-04:00",
            "2026-09-22T05:54:31+05:30",
        ] {
            #expect(ActivityTime.fastParse(sample) != nil, "\(sample)")
            let fast = ActivityTime.fastParse(sample)?.timeIntervalSince1970 ?? 0
            let slow = Parse.isoDate(sample)?.timeIntervalSince1970 ?? -1
            #expect(abs(fast - slow) < 0.000_5, "\(sample)")
        }
        #expect(ActivityTime.fastParse("2026-13-01T00:00:00Z") == nil)
        #expect(ActivityTime.fastParse("yesterday") == nil)
        #expect(ActivityTime.parse("yesterday") == nil)
    }
}
