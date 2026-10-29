import XCTest
@testable import CompanionKit

final class CompanionActivityTests: XCTestCase {
    private func activity(bucketTokens: [Int] = [10, 20], cost: Double = 0.5) -> CompanionActivity {
        CompanionActivity(
            capturedAt: Date(timeIntervalSince1970: 10), timeZoneIdentifier: "UTC",
            ranges: [
                CompanionActivityRange(
                    range: .week,
                    bucketStarts: [Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: 5)],
                    providers: [
                        CompanionProviderActivity(
                            name: "Claude", tokens: 30, cost: cost,
                            unpricedTokens: 10, sessions: 2, bucketTokens: bucketTokens,
                            bucketCost: [0.2, 0.3])
                    ])
            ])
    }

    func testActivityRoundTripAndRejectsMalformedParallelBuckets() throws {
        let value = activity()
        try value.validated()
        XCTAssertEqual(
            try JSONDecoder().decode(CompanionActivity.self, from: JSONEncoder().encode(value)),
            value)
        XCTAssertEqual(value.ranges[0].tokens, 30)
        XCTAssertEqual(value.ranges[0].unpricedTokens, 10)
        XCTAssertThrowsError(try activity(bucketTokens: [10]).validated())
        XCTAssertThrowsError(try activity(bucketTokens: [-1, 31]).validated())
        XCTAssertThrowsError(try activity(cost: .infinity).validated())
        XCTAssertThrowsError(try activity(cost: -1).validated())
        XCTAssertThrowsError(
            try CompanionActivity(
                capturedAt: .now, timeZoneIdentifier: "UTC",
                ranges: [value.ranges[0], value.ranges[0]]
            ).validated())
    }

    func testLegacyLimitsOnlySnapshotDecodesAndNewPayloadStaysBounded() throws {
        let old = CompanionSnapshot(
            sourceID: UUID(), sourceName: "Mac", revision: 1,
            publishedAt: .now, providers: [])
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        json.removeValue(forKey: "activity")
        XCTAssertNil(
            try CompanionSnapshot.decode(JSONSerialization.data(withJSONObject: json)).activity)
        let extended = CompanionSnapshot(
            sourceID: old.sourceID, sourceName: "Mac", revision: 2,
            publishedAt: .now, providers: [], activity: activity())
        let data = try JSONEncoder().encode(extended)
        XCTAssertLessThan(data.count, 512_000)
        XCTAssertEqual(try CompanionSnapshot.decode(data), extended)
    }
}
