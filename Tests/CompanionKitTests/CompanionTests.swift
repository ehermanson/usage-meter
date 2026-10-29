import XCTest
@testable import CompanionKit

final class CompanionTests: XCTestCase {
    private let source = UUID(uuidString: "C43FF2E5-534B-4B60-B99B-E32BD51BA9D0")!
    private let observed = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(revision: Int64 = 1, sourceID: UUID? = nil) -> CompanionSnapshot {
        CompanionSnapshot(
            sourceID: sourceID ?? source, sourceName: "My Mac", revision: revision,
            publishedAt: observed.addingTimeInterval(3600),
            providers: [
                CompanionProvider(
                    name: "Claude", plan: "Max", capturedAt: observed, status: .available,
                    windows: [
                        CompanionWindow(
                            id: "primary", pool: nil, label: "5h", usedPercent: 85,
                            resetAt: observed.addingTimeInterval(7200), duration: 18000)
                    ])
            ])
    }

    func testConnectionRoundTripAndRejectsAmbiguousOrForeignLinks() throws {
        XCTAssertEqual(
            try CompanionLink.sourceID(from: CompanionLink.url(sourceID: source)), source)
        for value in [
            "https://example.com/connect?v=1&source=\(source)",
            "usagemeter://connect?v=2&source=\(source)",
            "usagemeter://connect?v=1&source=\(source)&source=\(UUID())",
            "usagemeter://connect?v=1&source=bad",
            "usagemeter://connect?v=1&source=\(source)&token=secret",
            "usagemeter://connect/path?v=1&source=\(source)",
            "usagemeter://connect?v=1&source=\(source)#fragment",
        ] { XCTAssertThrowsError(try CompanionLink.sourceID(from: URL(string: value)!)) }
    }

    func testUploadTimeDoesNotRefreshObservationAgeOrInferReset() throws {
        let value = snapshot()
        let decoded = try CompanionSnapshot.decode(JSONEncoder().encode(value))
        XCTAssertEqual(decoded, value)
        let provider = try XCTUnwrap(decoded.providers.first)
        XCTAssertTrue(provider.isStale(at: value.publishedAt))
        XCTAssertFalse(provider.isExpired(at: observed.addingTimeInterval(86399)))
        XCTAssertTrue(provider.isExpired(at: observed.addingTimeInterval(86400)))
        let window = try XCTUnwrap(provider.windows.first)
        XCTAssertTrue(window.needsNewReading(at: observed.addingTimeInterval(7200)))
        XCTAssertEqual(window.usedPercent, 85)
    }

    func testCacheRejectsOldRevisionButAllowsDifferentSourceAndClearsOtherAccount() throws {
        var cache = CompanionCache()
        try cache.accept(snapshot(revision: 9), accountID: "A")
        try cache.accept(snapshot(revision: 8), accountID: "A")
        XCTAssertEqual(cache.snapshot?.revision, 9)
        let other = UUID()
        try cache.accept(snapshot(sourceID: other), accountID: "A")
        XCTAssertEqual(cache.selectedSourceID, other)
        try cache.accept(snapshot(), accountID: "B")
        XCTAssertEqual(cache.accountID, "B")
        XCTAssertEqual(cache.selectedSourceID, source)
    }

    func testUnknownSchemaAndDuplicateIDsAreRejected() throws {
        let data = try JSONEncoder().encode(snapshot())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["schemaVersion"] = 2
        XCTAssertThrowsError(
            try CompanionSnapshot.decode(JSONSerialization.data(withJSONObject: json)))
        let provider = snapshot().providers[0]
        let duplicate = CompanionSnapshot(
            sourceID: source, sourceName: "Mac", revision: 1,
            publishedAt: observed, providers: [provider, provider])
        XCTAssertThrowsError(try duplicate.validated())
        XCTAssertThrowsError(try CompanionSnapshot.decode(Data(repeating: 0, count: 512001)))
    }

    func testCacheAtomicRoundTripAndMismatchedSelectionIsRejected() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("cache.json")
        var cache = CompanionCache()
        try cache.accept(snapshot(), accountID: "A")
        try CompanionCacheFile.save(cache, to: file)
        XCTAssertEqual(CompanionCacheFile.load(from: file), cache)
        cache.selectedSourceID = UUID()
        try CompanionCacheFile.save(cache, to: file)
        XCTAssertNil(CompanionCacheFile.load(from: file).snapshot)
    }

    func testWidgetResponseCannotUndoDisconnectSourceSwitchOrAccountSwitch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("cache.json")
        var original = CompanionCache()
        try original.accept(snapshot(revision: 2), accountID: "A")
        try CompanionCacheFile.save(original, to: file)
        var next = CompanionCache()
        try next.accept(snapshot(sourceID: UUID()), accountID: "A")
        try CompanionCacheFile.save(next, to: file)
        XCTAssertEqual(
            try CompanionCacheFile.refresh(snapshot(revision: 9), accountID: "A", at: file), next)
        XCTAssertEqual(try CompanionCacheFile.clear(ifMatching: original, at: file), next)
        next = CompanionCache(accountID: "B")
        try CompanionCacheFile.save(next, to: file)
        XCTAssertEqual(
            try CompanionCacheFile.refresh(snapshot(revision: 10), accountID: "A", at: file), next)
        next = CompanionCache()
        try CompanionCacheFile.save(next, to: file)
        XCTAssertNil(
            try CompanionCacheFile.refresh(snapshot(revision: 11), accountID: "A", at: file)
                .snapshot)
    }

    func testAppSaveCannotReplaceNewerWidgetRevision() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: file.appendingPathExtension("lock"))
        }
        var old = CompanionCache()
        try old.accept(snapshot(revision: 1), accountID: "A")
        try CompanionCacheFile.save(old, to: file)
        _ = try CompanionCacheFile.refresh(snapshot(revision: 8), accountID: "A", at: file)
        try CompanionCacheFile.save(old, to: file)
        XCTAssertEqual(CompanionCacheFile.load(from: file).snapshot?.revision, 8)
    }
}
