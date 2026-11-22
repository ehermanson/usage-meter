import Foundation
import Testing

@testable import UsageMeter

private func agyStep(
    index: Int? = 1,
    type: String = "PLANNER_RESPONSE",
    source: String = "MODEL",
    model: String? = "gemini-4-neon-high",
    createdAt: String = "2026-11-21T20:01:25Z",
    input: Int? = 5000,
    cacheRead: Int? = 12000,
    output: Int? = 400
) -> String {
    var line: [String: Any] = [
        "source": source, "type": type, "status": "DONE", "created_at": createdAt,
    ]
    if let index { line["step_index"] = index }
    if let model { line["model"] = model }
    if let input { line["input_tokens"] = input }
    if let cacheRead { line["cache_read_tokens"] = cacheRead }
    if let output { line["output_tokens"] = output }
    let data = try! JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

private func parse(
    _ lines: [String], conversationId: String = "conv-1", sessionId: String? = nil,
    until cutoff: Date? = nil
) -> [UsageRecord] {
    let parser = AntigravityLogParser(
        conversationId: conversationId, sessionId: sessionId, until: cutoff)
    let decoder = JSONDecoder()
    for line in lines { parser.consume(Data(line.utf8), decoder: decoder) }
    return parser.records
}

@Suite("Antigravity log parsing")
struct ActivityAntigravityParserTests {
    @Test("parses PLANNER_RESPONSE steps with disjoint input and cache-read counts")
    func parsesPlannerResponse() throws {
        let records = parse([
            agyStep(
                index: 5, model: "gemini-4-neon-high", createdAt: "2026-11-21T20:01:25Z",
                input: 5589, cacheRead: 12901, output: 386)
        ])
        let record = try #require(records.first)
        #expect(records.count == 1)
        #expect(record.provider == "Antigravity")
        #expect(record.model == "gemini-4-neon-high")
        #expect(record.sessionId == "conv-1")
        #expect(record.dedupeKey == "conv-1:5")
        #expect(
            record.tokens
                == TokenCounts(input: 5589, output: 386, cacheRead: 12901, cacheWrite: 0))
        #expect(record.timestamp == Parse.isoDate("2026-11-21T20:01:25Z"))
    }

    @Test("skips non-planner steps, zero-token lines, and malformed JSON")
    func skipsNonBillable() {
        let records = parse([
            agyStep(
                index: 0, type: "USER_INPUT", source: "USER_EXPLICIT", model: nil, input: nil,
                cacheRead: nil, output: nil),
            agyStep(
                index: 2, type: "GENERIC", source: "MODEL", model: nil, input: nil, cacheRead: nil,
                output: nil),
            agyStep(index: 3, model: nil, input: nil, cacheRead: nil, output: nil),
            agyStep(index: 4, input: 0, cacheRead: 0, output: 0),
            "not json \"PLANNER_RESPONSE\"",
            agyStep(index: 7, input: 100, cacheRead: 0, output: 20),
        ])
        #expect(records.map(\.dedupeKey) == ["conv-1:7"])
    }

    @Test("respects the --now cutoff")
    func respectsCutoff() throws {
        let cut = try #require(Parse.isoDate("2026-11-21T20:02:00Z"))
        let records = parse(
            [
                agyStep(index: 1, createdAt: "2026-11-21T20:01:00Z", output: 10),
                agyStep(index: 2, createdAt: "2026-11-21T20:02:00Z", output: 20),
                agyStep(index: 3, createdAt: "2026-11-21T20:02:01Z", output: 30),
            ], until: cut)
        #expect(records.map(\.tokens.output) == [10, 20])
    }

    @Test("home resolution follows ANTIGRAVITY_DIR > GEMINI_HOME > ~/.gemini")
    func homePrecedence() {
        let agyDir = AntigravityLogSource.home(
            environment: ["ANTIGRAVITY_DIR": "/tmp/a", "GEMINI_HOME": "/tmp/b"],
            home: "/Users/test")
        #expect(agyDir.path == ActivitySources.resolved("/tmp/a").path)

        let geminiHome = AntigravityLogSource.home(
            environment: ["GEMINI_HOME": "/tmp/b"], home: "/Users/test")
        #expect(geminiHome.path == ActivitySources.resolved("/tmp/b").path)

        let fallback = AntigravityLogSource.home(environment: [:], home: "/Users/test")
        #expect(fallback.path == ActivitySources.resolved("/Users/test/.gemini").path)
    }

    @Test(
        "discovers brain transcripts under .system_generated and rolls subagents into parent session"
    )
    func discoversAndRollsUpSubagents() async throws {
        let fm = FileManager.default
        let brain = fm.temporaryDirectory.appendingPathComponent("agy-brain-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: brain) }

        func write(_ rel: String, _ text: String) throws {
            let file = brain.appendingPathComponent(rel)
            try fm.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }

        // Parent conversation + a compact transcript.jsonl beside it (must be ignored).
        try write(
            "parent-1/.system_generated/logs/transcript_full.jsonl",
            agyStep(
                index: 0, type: "USER_INPUT", source: "USER_EXPLICIT", input: nil, cacheRead: nil,
                output: nil)
                + "\n"
                + agyStep(index: 1, input: 1000, cacheRead: 0, output: 50) + "\n")
        try write(
            "parent-1/.system_generated/logs/transcript.jsonl",
            agyStep(index: 1, input: 9999, cacheRead: 0, output: 9999) + "\n")
        // Subagent launched by parent-1, plus a grandchild launched by child-1.
        try write("parent-1/.system_generated/subagents/child-1.json", "{}")
        try write(
            "child-1/.system_generated/logs/transcript_full.jsonl",
            agyStep(index: 1, input: 200, cacheRead: 100, output: 20) + "\n")
        try write("child-1/.system_generated/subagents/grandchild-1.json", "{}")
        try write(
            "grandchild-1/.system_generated/logs/transcript_full.jsonl",
            agyStep(index: 1, input: 50, cacheRead: 0, output: 10) + "\n")
        // Separate top-level conversation.
        try write(
            "other-2/.system_generated/logs/transcript_full.jsonl",
            agyStep(index: 1, input: 300, cacheRead: 0, output: 30) + "\n")

        let source = AntigravityLogSource(brainDir: brain)
        let scanner = ActivityScanner(sources: [source])
        let result = await scanner.scan()

        #expect(result.detectedProviders == ["Antigravity"])
        #expect(result.records.count == 4)
        // parent-1, child-1, grandchild-1 all share sessionId "parent-1"; other-2 is its own.
        #expect(Set(result.records.map(\.sessionId)) == ["parent-1", "other-2"])
        let totalTokens = result.records.reduce(0) { $0 + $1.tokens.total }
        #expect(totalTokens == 1760)
    }

    @Test("child scanned before its subagent link appears heals its sessionId on the next update")
    func subagentLinkAppearingLater() async throws {
        let fm = FileManager.default
        let brain = fm.temporaryDirectory.appendingPathComponent("agy-race-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: brain) }

        func write(_ rel: String, _ text: String) throws {
            let file = brain.appendingPathComponent(rel)
            try fm.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }
        func append(_ rel: String, _ text: String) throws {
            let handle = try FileHandle(forWritingTo: brain.appendingPathComponent(rel))
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
        }

        try write(
            "parent-1/.system_generated/logs/transcript_full.jsonl",
            agyStep(index: 1, input: 100, cacheRead: 0, output: 10) + "\n")
        try write(
            "child-1/.system_generated/logs/transcript_full.jsonl",
            agyStep(index: 1, input: 200, cacheRead: 0, output: 20) + "\n")

        let scanner = ActivityScanner(sources: [AntigravityLogSource(brainDir: brain)])
        let first = await scanner.scan()
        #expect(Set(first.records.map(\.sessionId)) == ["parent-1", "child-1"])

        // Subagent metadata lands and the parent appends its next step.
        try write("parent-1/.system_generated/subagents/child-1.json", "{}")
        try append(
            "parent-1/.system_generated/logs/transcript_full.jsonl",
            agyStep(index: 2, input: 150, cacheRead: 100, output: 15) + "\n")

        let second = await scanner.scan()
        #expect(Set(second.records.map(\.sessionId)) == ["parent-1"])
    }
}
