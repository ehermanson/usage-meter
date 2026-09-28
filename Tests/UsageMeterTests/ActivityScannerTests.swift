import Foundation
import Testing

@testable import UsageMeter

/// A Claude-format source rooted at a temp dir, so the scanner's file
/// handling runs against real files without touching the user's logs.
private struct TempClaudeSource: ActivityLogSource {
    let root: URL
    let name = "Claude"
    let markers = ["\"usage\""]
    func logFiles() -> [URL] { ActivitySources.jsonlFiles(under: [root]) }
    func makeParser(for file: URL) -> ActivityLogParser {
        ClaudeLogParser(fallbackSessionId: ClaudeLogSource.sessionId(forFile: file))
    }
}

/// Codex's format under a temp dir, with the real source's markers.
private struct TempCodexSource: ActivityLogSource {
    let root: URL
    let name = "Codex"
    let markers = CodexLogSource().markers
    func logFiles() -> [URL] { ActivitySources.jsonlFiles(under: [root]) }
    func makeParser(for file: URL) -> ActivityLogParser {
        CodexLogParser(fallbackSessionId: CodexLogSource.sessionId(forFile: file))
    }
}

private final class TempLogs {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("activity-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }

    func url(_ name: String) -> URL { root.appendingPathComponent(name) }

    func write(_ name: String, _ text: String) throws {
        let file = url(name)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    func append(_ name: String, _ text: String) throws {
        let handle = try FileHandle(forWritingTo: url(name))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    func scanner(
        chunkSize: Int = ActivityScanner.defaultChunkSize,
        maxLineLength: Int = ActivityScanner.defaultMaxLineLength
    ) -> ActivityScanner {
        ActivityScanner(
            sources: [TempClaudeSource(root: root)], chunkSize: chunkSize,
            maxLineLength: maxLineLength)
    }

    func codexScanner(chunkSize: Int = ActivityScanner.defaultChunkSize) -> ActivityScanner {
        ActivityScanner(sources: [TempCodexSource(root: root)], chunkSize: chunkSize)
    }
}

/// Lines joined as a JSONL file's text, each newline-terminated.
private func jsonl(_ lines: [String]) -> String {
    lines.map { $0 + "\n" }.joined()
}

/// A line with a distinct response id per `n`, plus filler that isn't usage.
private func line(_ n: Int, output: Int = 10) -> String {
    claudeLine(id: "msg_\(n)", request: "req_\(n)", output: output) + "\n"
}

private let filler = #"{"type":"user","message":{"role":"user","content":"hello"}}"# + "\n"

@Suite("Incremental log scanning")
struct ActivityScannerTests {
    @Test("appended lines are read from the saved offset, not from the start")
    func readsOnlyAppendedBytes() async throws {
        let logs = try TempLogs()
        try logs.write("p/a.jsonl", line(1) + filler + line(2))
        let scanner = logs.scanner()

        let first = await scanner.scan()
        #expect(first.records.count == 2)
        #expect(first.detectedProviders == ["Claude"])

        let unchanged = await scanner.scan()
        #expect(unchanged.records.count == 2)
        #expect(unchanged.stats.filesRead == 0)
        #expect(unchanged.stats.bytesRead == 0)

        let appended = line(3)
        try logs.append("p/a.jsonl", appended)
        let second = await scanner.scan()
        #expect(second.records.map(\.dedupeKey) == ["msg_1:req_1", "msg_2:req_2", "msg_3:req_3"])
        #expect(second.stats.bytesRead == Int64(appended.utf8.count))
    }

    @Test("a partial trailing line waits until it's complete, then counts once")
    func partialTrailingLine() async throws {
        let logs = try TempLogs()
        let whole = line(2, output: 77)
        let cut = whole.utf8.count / 2
        try logs.write("a.jsonl", line(1) + String(whole.prefix(cut)))
        let scanner = logs.scanner()

        #expect(await scanner.scan().records.count == 1)
        try logs.append("a.jsonl", String(whole.dropFirst(cut)))
        let records = await scanner.scan().records
        #expect(records.count == 2)
        #expect(records.last?.tokens.output == 77)
        #expect(await scanner.scan().records.count == 2)
    }

    @Test("a truncated file is read again from the start")
    func truncationResets() async throws {
        let logs = try TempLogs()
        try logs.write("a.jsonl", line(1) + line(2) + line(3))
        let scanner = logs.scanner()
        #expect(await scanner.scan().records.count == 3)

        try logs.write("a.jsonl", line(9))
        let records = await scanner.scan().records
        #expect(records.map(\.dedupeKey) == ["msg_9:req_9"])
    }

    @Test("a replaced file (new inode, not smaller) is read again from the start")
    func replacementResets() async throws {
        let logs = try TempLogs()
        try logs.write("a.jsonl", line(1))
        let scanner = logs.scanner()
        #expect(await scanner.scan().records.count == 1)

        // Written elsewhere and moved over the original: same path, new file.
        try logs.write("staging.txt", line(7) + line(8))
        _ = try FileManager.default.replaceItemAt(
            logs.url("a.jsonl"), withItemAt: logs.url("staging.txt"))
        let records = await scanner.scan().records
        #expect(records.map(\.dedupeKey) == ["msg_7:req_7", "msg_8:req_8"])
    }

    @Test("a file rewritten in place (same inode, bigger) is read again from the start")
    func inPlaceRewriteResets() async throws {
        let logs = try TempLogs()
        try logs.write("a.jsonl", line(1) + line(2))
        let scanner = logs.scanner()
        #expect(await scanner.scan().records.count == 2)

        // Truncated and rewritten through the same descriptor, longer than
        // before, so neither the inode nor a shrinking size gives it away.
        let path = logs.url("a.jsonl").path
        func inode() throws -> Int? {
            try FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber] as? Int
        }
        let before = try inode()
        let handle = try FileHandle(forWritingTo: logs.url("a.jsonl"))
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data((line(7) + filler + line(8) + line(9)).utf8))
        try handle.close()
        #expect(try inode() == before)

        let records = await scanner.scan().records
        #expect(records.map(\.dedupeKey) == ["msg_7:req_7", "msg_8:req_8", "msg_9:req_9"])

        // The new content is now what's tracked: appending reads on as usual.
        try logs.append("a.jsonl", line(10))
        let appended = await scanner.scan()
        #expect(appended.records.count == 4)
        #expect(appended.stats.bytesRead == Int64(line(10).utf8.count))
    }

    @Test("a file that started out shorter than the head still has a rewrite caught")
    func shortFileRewriteResets() async throws {
        let logs = try TempLogs()
        // Nothing complete yet: a partial first line, well under the head.
        let whole = line(1)
        try logs.write("a.jsonl", String(whole.prefix(20)))
        let scanner = logs.scanner()
        #expect(await scanner.scan().records.isEmpty)
        try logs.append("a.jsonl", String(whole.dropFirst(20)) + line(2))
        #expect(await scanner.scan().records.count == 2)

        // Rewritten in place with a different first line, bigger than before.
        let handle = try FileHandle(forWritingTo: logs.url("a.jsonl"))
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data((line(5) + line(6) + line(7)).utf8))
        try handle.close()
        let records = await scanner.scan().records
        #expect(records.map(\.dedupeKey) == ["msg_5:req_5", "msg_6:req_6", "msg_7:req_7"])
    }

    @Test("records are rebuilt only when a file's records could have changed")
    func generationTracksChanges() async throws {
        let logs = try TempLogs()
        try logs.write("a.jsonl", line(1))
        let scanner = logs.scanner()
        let first = await scanner.scan()

        // Nothing new: same records.
        #expect(await scanner.scan().generation == first.generation)

        // A partial line, or a touched mtime, is read but consumes nothing.
        let whole = line(2)
        try logs.append("a.jsonl", String(whole.prefix(10)))
        let partial = await scanner.scan()
        #expect(partial.stats.filesRead == 1)
        #expect(partial.generation == first.generation)
        try FileManager.default.setAttributes(
            [.modificationDate: Date.now.addingTimeInterval(5)],
            ofItemAtPath: logs.url("a.jsonl").path)
        #expect(await scanner.scan().generation == first.generation)

        // Completing the line does change them.
        try logs.append("a.jsonl", String(whole.dropFirst(10)))
        let completed = await scanner.scan()
        #expect(completed.records.count == 2)
        #expect(completed.generation > first.generation)

        // So does a file going away.
        try logs.write("b.jsonl", line(3))
        let added = await scanner.scan()
        #expect(added.generation > completed.generation)
        try FileManager.default.removeItem(at: logs.url("b.jsonl"))
        let removed = await scanner.scan()
        #expect(removed.generation > added.generation)
        #expect(removed.records.count == 2)
    }

    @Test(
        "a file that stays unreadable doesn't rebuild the records every scan",
        .enabled(if: getuid() != 0, "root reads a file whatever its mode"))
    func unreadableFileLeavesRecordsAlone() async throws {
        let logs = try TempLogs()
        try logs.write("a.jsonl", line(1))
        try logs.write("b.jsonl", line(2))
        let path = logs.url("b.jsonl").path
        defer { chmod(path, 0o644) }
        #expect(chmod(path, 0) == 0)
        let scanner = logs.scanner()

        let first = await scanner.scan()
        #expect(first.records.count == 1)
        // Tried again each time, since it might have become readable…
        let second = await scanner.scan()
        #expect(second.stats.filesRead == 1)
        // …but a try that reads nothing changes nothing.
        #expect(second.generation == first.generation)
        #expect(await scanner.scan().generation == first.generation)

        #expect(chmod(path, 0o644) == 0)
        let readable = await scanner.scan()
        #expect(readable.records.count == 2)
        #expect(readable.generation > first.generation)
    }

    @Test("overlapping scans of one scanner run one at a time and agree")
    func concurrentScans() async throws {
        let logs = try TempLogs()
        for n in 1...20 { try logs.write("p\(n)/a.jsonl", line(n) + filler + line(100 + n)) }
        let scanner = logs.scanner(chunkSize: 64)
        let results = await withTaskGroup(of: ActivityScanResult.self) { group in
            for _ in 0..<8 { group.addTask { await scanner.scan() } }
            return await group.reduce(into: []) { $0.append($1) }
        }
        // The first to run read everything; the rest found nothing new.
        #expect(results.map(\.stats.bytesRead).filter { $0 > 0 }.count == 1)
        #expect(Set(results.map(\.generation)).count == 1)
        for result in results {
            #expect(result.records.count == 40)
        }
    }

    @Test("vanished files are forgotten; files past the age cutoff are skipped")
    func vanishedAndAgedFiles() async throws {
        let logs = try TempLogs()
        try logs.write("keep.jsonl", line(1))
        try logs.write("gone.jsonl", line(2))
        try logs.write("old.jsonl", line(3))
        let old = Date.now.addingTimeInterval(-100 * 24 * 3600)
        try FileManager.default.setAttributes(
            [.modificationDate: old], ofItemAtPath: logs.url("old.jsonl").path)
        let scanner = logs.scanner()

        let first = await scanner.scan()
        #expect(Set(first.records.compactMap(\.dedupeKey)) == ["msg_1:req_1", "msg_2:req_2"])
        #expect(first.stats.files == 2)

        try FileManager.default.removeItem(at: logs.url("gone.jsonl"))
        #expect(await scanner.scan().records.compactMap(\.dedupeKey) == ["msg_1:req_1"])
    }

    @Test("no log files: nothing detected")
    func nothingDetected() async throws {
        let logs = try TempLogs()
        try logs.write("notes.txt", line(1))
        let result = await logs.scanner().scan()
        #expect(result.records.isEmpty)
        #expect(result.detectedProviders.isEmpty)
    }

    @Test("lines split across reads, or longer than a whole read, are reassembled")
    func chunkBoundaries() async throws {
        let logs = try TempLogs()
        let big = claudeLine(id: "msg_big", request: "req_big", output: 42)
            .replacingOccurrences(of: "Some", with: String(repeating: "x", count: 5000))
        let text = (1...20).map { line($0) + filler }.joined() + big + "\n" + line(21)
        try logs.write("a.jsonl", text)
        // Chunks far smaller than a line: every line straddles reads, and the
        // long one is many reads long.
        for chunk in [64, 100, 333, 4096] {
            let records = await logs.scanner(chunkSize: chunk).scan().records
            let expected =
                (1...20).map { "msg_\($0):req_\($0)" } + ["msg_big:req_big", "msg_21:req_21"]
            #expect(records.map(\.dedupeKey) == expected, "chunk \(chunk)")
            #expect(records.first { $0.dedupeKey == "msg_big:req_big" }?.tokens.output == 42)
        }
        // Appending with a tiny buffer still picks up exactly the new line.
        let scanner = logs.scanner(chunkSize: 64)
        #expect(await scanner.scan().records.count == 22)
        try logs.append("a.jsonl", line(22))
        #expect(await scanner.scan().records.count == 23)
    }

    @Test("lines longer than a read: passed over without a marker, read whole with one")
    func longLines() async throws {
        let logs = try TempLogs()
        // A pasted image: no marker, and many reads long.
        let image =
            #"{"type":"user","message":{"content":""# + String(repeating: "A", count: 10_000)
            + #""}}"# + "\n"
        // Long lines whose marker falls at every offset across a read
        // boundary, so one split between two reads must still be found.
        let long = (0..<60).map {
            claudeLine(id: "msg_long\($0)", request: "req", output: $0 + 1)
                .replacingOccurrences(of: "Some", with: String(repeating: "x", count: 200 + $0))
                + "\n"
        }
        try logs.write("a.jsonl", line(1) + image + long.joined() + image + line(2))
        let expected = ["msg_1:req_1"] + (0..<60).map { "msg_long\($0):req" } + ["msg_2:req_2"]
        for chunk in [64, 100, 333, 4096] {
            let records = await logs.scanner(chunkSize: chunk).scan().records
            #expect(records.map(\.dedupeKey) == expected, "chunk \(chunk)")
            #expect(records.dropFirst().prefix(60).map(\.tokens.output) == Array(1...60))
        }

        // One still being written waits until its newline, then counts once.
        let big = long[59]
        let cut = big.utf8.count / 2
        try logs.write("b.jsonl", line(3) + String(big.prefix(cut)))
        let scanner = logs.scanner(chunkSize: 64)
        #expect(await scanner.scan().records.count == expected.count + 1)
        try logs.append("b.jsonl", String(big.dropFirst(cut)))
        #expect(await scanner.scan().records.count == expected.count + 2)
        #expect(await scanner.scan().records.count == expected.count + 2)
    }

    @Test("a line with a marker past the length cap is skipped, and the rest still read")
    func overlongLine() async throws {
        let logs = try TempLogs()
        let huge = claudeLine(id: "msg_huge", request: "req_huge")
            .replacingOccurrences(of: "Some", with: String(repeating: "x", count: 5000))
        try logs.write("a.jsonl", line(1) + huge + "\n" + line(2))
        let records = await logs.scanner(chunkSize: 64, maxLineLength: 1000).scan().records
        #expect(records.map(\.dedupeKey) == ["msg_1:req_1", "msg_2:req_2"])
    }

    @Test(
        "a file that can't be read is tried again until it can, from where it left off",
        .enabled(if: getuid() != 0, "root reads a file whatever its mode"))
    func unreadableFileRetried() async throws {
        let logs = try TempLogs()
        try logs.write("a.jsonl", line(1))
        try logs.write("b.jsonl", line(2) + line(3))
        let path = logs.url("b.jsonl").path
        defer { chmod(path, 0o644) }
        func mtime() throws -> Date? {
            try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
        }
        let scanner = logs.scanner()

        // Unreadable when first seen — root-owned from a `sudo` run, say.
        #expect(chmod(path, 0) == 0)
        #expect(await scanner.scan().records.compactMap(\.dedupeKey) == ["msg_1:req_1"])
        #expect(await scanner.scan().records.count == 1)
        // A permissions fix changes neither its size nor its mtime.
        let before = try mtime()
        #expect(chmod(path, 0o644) == 0)
        #expect(try mtime() == before)
        let keys = ["msg_1:req_1", "msg_2:req_2", "msg_3:req_3"]
        #expect(await scanner.scan().records.compactMap(\.dedupeKey) == keys)

        // Unreadable again after it grew: its first lines stay counted, and
        // the new one is read, once, when it can be.
        try logs.append("b.jsonl", line(4))
        #expect(chmod(path, 0) == 0)
        #expect(await scanner.scan().records.compactMap(\.dedupeKey) == keys)
        #expect(chmod(path, 0o644) == 0)
        #expect(await scanner.scan().records.compactMap(\.dedupeKey) == keys + ["msg_4:req_4"])
        #expect(await scanner.scan().stats.filesRead == 0)
    }

    @Test("a log directory that's a symlink is followed, and listed once beside its target")
    func symlinkedRoot() async throws {
        let logs = try TempLogs()
        try logs.write("elsewhere/p/a.jsonl", line(1))
        let target = logs.url("elsewhere")
        // Moved to another volume and linked back.
        let link = logs.url("projects")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        // A loop further down isn't followed.
        try FileManager.default.createSymbolicLink(
            at: target.appendingPathComponent("p/up"), withDestinationURL: target)

        #expect(ActivitySources.jsonlFiles(under: [link]).map(\.lastPathComponent) == ["a.jsonl"])
        #expect(ActivitySources.jsonlFiles(under: [target, link]).count == 1)
        let result = await ActivityScanner(sources: [TempClaudeSource(root: link)]).scan()
        #expect(result.records.compactMap(\.dedupeKey) == ["msg_1:req_1"])
        #expect(result.detectedProviders == ["Claude"])
    }

    @Test("Claude copies merge across reads: partial first, then the final and a zero copy")
    func claudeCopiesAcrossReads() async throws {
        let logs = try TempLogs()
        let copy = {
            (t: String, output: Int, cacheWrite: Int, oneHour: Int, speed: String?) -> String in
            claudeLine(
                id: "msg_x", request: "req_x", timestamp: t, input: 56, output: output,
                cacheRead: output == 0 ? 0 : 491_973, cacheWrite: cacheWrite, oneHour: oneHour,
                speed: speed) + "\n"
        }
        try logs.write(
            "p/a.jsonl", copy("2026-09-20T16:56:08.354Z", 8, 523, 0, nil) + filler)
        let scanner = logs.scanner()
        let first = try #require(await scanner.scan().records.first)
        #expect(first.tokens.output == 8)
        #expect(!first.fast)

        // The final copy, fast, lands in the next read.
        try logs.append("p/a.jsonl", copy("2026-09-20T16:56:08.380Z", 709, 523, 0, "fast"))
        let merged = await scanner.scan().records
        #expect(merged.count == 1)
        #expect(merged.first?.tokens.output == 709)
        #expect(merged.first?.fast == true)
        #expect(merged.first?.timestamp == Parse.isoDate("2026-09-20T16:56:08.354Z"))

        // A zero copy with a 1h figure, much later in the file: dropped, so
        // the write stays all 5-minute.
        let zero = claudeLine(
            id: "msg_x", request: "req_x", timestamp: "2026-09-20T16:56:08.354Z", input: 0,
            output: 0, cacheRead: 0, cacheWrite: 0, oneHour: 523, speed: nil)
        try logs.append("p/a.jsonl", filler + zero + "\n" + line(2))
        let after = await scanner.scan().records
        #expect(after.map(\.dedupeKey) == ["msg_x:req_x", "msg_2:req_2"])
        #expect(after.first?.tokens.cacheWrite == 523)
        #expect(after.first?.cacheWrite1h == 0)
        let deduped = ActivityAggregator.dedupe(after)
        #expect(deduped.first?.cacheWrite1h == 0)
        #expect(deduped.first?.tokens.output == 709)
    }

    @Test("a Codex file's first usage record in a later read keeps what came before")
    func codexUsageRecordArrivesLater() async throws {
        typealias F = CodexFixture
        let logs = try TempLogs()
        let name = "sessions/2026/08/14/rollout-2026-08-14T12-41-43-01a00126.jsonl"
        try logs.write(name, jsonl(F.mixedOldCLI))
        let scanner = logs.codexScanner()
        let before = await scanner.scan().records
        #expect(before.map(\.tokens.total) == Array(F.mixedTotals.prefix(2)))

        // Resumed on a newer CLI: its records count, its token_counts don't,
        // and what the old CLI logged stays counted.
        try logs.append(name, jsonl(F.mixedResumed))
        let after = await scanner.scan()
        #expect(after.stats.filesRead == 1)
        #expect(after.records.map(\.tokens.total) == F.mixedTotals)
        #expect(Array(after.records.prefix(2)) == before)

        // The same whole file read cold, with reads small enough that the
        // first record lands in a later chunk of the one pass.
        for chunk in [64, 200, 1024] {
            let cold = await logs.codexScanner(chunkSize: chunk).scan().records
            #expect(cold.map(\.tokens.total) == F.mixedTotals, "chunk \(chunk)")
        }
    }

    @Test("a Codex fork's replay isn't counted, whenever its own turn is read")
    func codexForkReplayAcrossReads() async throws {
        typealias F = CodexFixture
        let logs = try TempLogs()
        let name = "sessions/2026/07/25/rollout-2026-07-25T20-18-28-019f9bc9.jsonl"
        try logs.write(name, jsonl(F.forkReplay))
        let scanner = logs.codexScanner()
        #expect(await scanner.scan().records.isEmpty)

        // The fork's own work arrives later; it's measured from the replay's
        // last total, not from zero.
        try logs.append(name, jsonl(Array(F.forkOwnTurn.prefix(2))))
        #expect(await scanner.scan().records.map(\.tokens.total) == [F.forkOwnTotals[0]])
        try logs.append(name, jsonl(Array(F.forkOwnTurn.dropFirst(2))))
        #expect(await scanner.scan().records.map(\.tokens.total) == F.forkOwnTotals)

        for chunk in [64, 200, 1024] {
            let cold = await logs.codexScanner(chunkSize: chunk).scan().records
            #expect(cold.map(\.tokens.total) == F.forkOwnTotals, "chunk \(chunk)")
        }
    }

    @Test("marker search finds the earliest of several markers, including at the edges")
    func markerSearch() {
        let set = MarkerSet(["\"token_count\"", "\"session_meta\"", "\"usage\""])
        func find(_ text: String, from: Int = 0) -> Int? {
            let bytes = Array(text.utf8)
            return bytes.withUnsafeBufferPointer {
                set.firstMatch($0.baseAddress!, from: from, to: bytes.count)
            }
        }
        let pad = String(repeating: "a", count: 40)
        #expect(find(pad + "\"usage\"" + pad + "\"token_count\"") == 40)
        #expect(find(pad + "\"session_meta\"" + pad + "\"usage\"") == 40)
        #expect(find("\"usage\"") == 0)  // shorter than one vector step
        #expect(find(pad + pad + "\"usage\"") == 80)  // in the scalar tail
        #expect(find(pad + "\"usage") == nil)  // cut off at the end
        #expect(find(pad + "\\\"usage\\\"" + pad) == nil)  // escaped, inside a string
        #expect(find(pad + "usages" + pad) == nil)
        #expect(find("\"usage\"" + pad + "\"usage\"", from: 1) == 47)

        let bytes = Array("ab\ncd\nef".utf8)
        bytes.withUnsafeBufferPointer {
            #expect(ActivityScanner.lastNewline($0.baseAddress!, from: 0, before: 8) == 5)
            #expect(ActivityScanner.lastNewline($0.baseAddress!, from: 0, before: 5) == 2)
            #expect(ActivityScanner.lastNewline($0.baseAddress!, from: 3, before: 5) == nil)
        }
    }
}
