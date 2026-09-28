import Foundation
import Testing

@testable import UsageMeter

/// A Claude-format source over a temp dir that reports each scan listing it
/// and holds the first one there until released, so callers can be lined up
/// behind a scan that's still running.
private final class HeldSource: ActivityLogSource, @unchecked Sendable {
    let root: URL
    let name = "Claude"
    let markers = ["\"usage\""]
    /// One element per scan, as it starts.
    let scansStarted: AsyncStream<Void>
    private let started: AsyncStream<Void>.Continuation
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var listed = 0

    init(root: URL) {
        self.root = root
        (scansStarted, started) = AsyncStream.makeStream()
    }

    var scans: Int { lock.withLock { listed } }

    func release() { gate.signal() }

    func logFiles() -> [URL] {
        let scan = lock.withLock {
            listed += 1
            return listed
        }
        started.yield()
        // On the scanner's own queue, so holding it here holds only the scan.
        if scan == 1 { gate.wait() }
        return ActivitySources.jsonlFiles(under: [root])
    }

    func makeParser(for file: URL) -> ActivityLogParser {
        ClaudeLogParser(fallbackSessionId: ClaudeLogSource.sessionId(forFile: file))
    }
}

@MainActor
@Suite("Activity store")
struct ActivityStoreTests {
    @Test("forced refreshes queued behind one scan share the next, rather than overlap")
    func forcedRefreshesShareTheNextScan() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "activity-store-\(UUID().uuidString)")
        let logs = root.appendingPathComponent("logs")
        try fm.createDirectory(at: logs, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let stamp = Date.now.addingTimeInterval(-3600).formatted(.iso8601)
        try Data((claudeLine(timestamp: stamp) + "\n").utf8)
            .write(to: logs.appendingPathComponent("session.jsonl"))
        // Written just now, so no price download is due.
        let prices = root.appendingPathComponent("prices.json")
        try Data("{}".utf8).write(to: prices)

        let source = HeldSource(root: logs)
        let store = ActivityStore(
            scanner: ActivityScanner(sources: [source]), priceCache: prices)
        var scansStarted = source.scansStarted.makeAsyncIterator()

        // Opening the panel starts a scan, and a Refresh click and a Claude
        // folder change both come in while it runs.
        let opened = Task { await store.refresh() }
        await scansStarted.next()
        let clicked = Task { await store.refresh(force: true) }
        let folderChanged = Task { await store.refresh(force: true) }
        // Main-actor jobs run in order, so both are waiting on the held scan
        // by the time this resumes.
        await Task.yield()
        source.release()
        await opened.value
        await clicked.value
        await folderChanged.value

        // The held scan, then one more for both forced calls.
        #expect(source.scans == 2)
        #expect(store.summary?.totalTokens == 102)
    }
}
