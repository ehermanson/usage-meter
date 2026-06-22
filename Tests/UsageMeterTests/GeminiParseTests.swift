import Foundation
import Testing

@testable import UsageMeter

@Suite("Gemini quota parsing")
struct GeminiParseTests {
    /// An ISO-8601 reset time a given number of hours from now.
    private func reset(hoursFromNow: Double) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date().addingTimeInterval(hoursFromNow * 3600))
    }

    @Test("collapses available buckets into one Daily window at the highest usage")
    func collapsesToDaily() {
        let buckets: [[String: Any]] = [
            [
                "modelId": "gemini-2.5-flash", "remainingFraction": 1.0,
                "resetTime": reset(hoursFromNow: 20),
            ],
            [
                "modelId": "gemini-3-flash-preview", "remainingFraction": 0.25,
                "resetTime": reset(hoursFromNow: 24),
            ],
        ]
        let usage = GeminiClient.parse(buckets)

        #expect(usage.error == nil)
        #expect(usage.allWindows.count == 1)
        #expect(usage.allWindows[0].label == "Daily")
        // remainingFraction 0.25 -> 75% used is the most-consumed model.
        #expect(usage.allWindows[0].usedPercent == 75.0)
        // The soonest reset (20h) wins.
        #expect(usage.allWindows[0].resetAt != nil)
    }

    @Test("locked tier models (epoch reset) are skipped")
    func skipsLockedModels() {
        let buckets: [[String: Any]] = [
            [
                "modelId": "gemini-2.5-flash", "remainingFraction": 1.0,
                "resetTime": reset(hoursFromNow: 12),
            ],
            [
                "modelId": "gemini-3-pro-preview", "remainingFraction": 0.0,
                "resetTime": "1970-01-01T00:00:00Z",
            ],
        ]
        let usage = GeminiClient.parse(buckets)

        #expect(usage.allWindows.count == 1)
        #expect(usage.allWindows[0].usedPercent == 0.0)  // the pro model was ignored
    }

    @Test("no available buckets yields a retryable failure")
    func noAvailableFails() {
        let buckets: [[String: Any]] = [
            [
                "modelId": "gemini-3-pro-preview", "remainingFraction": 0.0,
                "resetTime": "1970-01-01T00:00:00Z",
            ]
        ]
        let usage = GeminiClient.parse(buckets)
        #expect(usage.error != nil)
        #expect(!usage.hasWindows)
        #expect(usage.retryable)
    }
}

@Suite("Gemini credential selection")
struct GeminiCredentialTests {
    typealias Creds = GeminiClient.Credentials
    let now = Date(timeIntervalSince1970: 1_000_000)

    private func creds(access: String, refresh: String?, expiresInSec: Double?) -> Creds {
        Creds(
            accessToken: access,
            refreshToken: refresh,
            expiry: expiresInSec.map { now.addingTimeInterval($0) },
            clientID: "cid", clientSecret: "secret")
    }

    /// A refresh stub that fails unless the credential is in `succeedFor`.
    private func refresher(
        succeedFor: Set<String> = []
    ) -> (Creds, String) async throws -> (value: String, expiry: Date) {
        { c, _ in
            guard succeedFor.contains(c.accessToken) else {
                struct Boom: Error {}
                throw Boom()
            }
            return ("refreshed:\(c.accessToken)", self.now.addingTimeInterval(3600))
        }
    }

    @Test("a still-valid first source is used without refreshing")
    func firstValidWins() async throws {
        let candidates = [
            creds(access: "antigravity", refresh: "r1", expiresInSec: 3600),
            creds(access: "geminicli", refresh: "r2", expiresInSec: 3600),
        ]
        let token = try await GeminiClient.selectToken(
            from: candidates, now: now, refresh: refresher())
        #expect(token.value == "antigravity")
    }

    @Test("expired first source with failing refresh falls through to a valid second")
    func fallsThroughToSecondSource() async throws {
        let candidates = [
            creds(access: "antigravity", refresh: "r1", expiresInSec: -10),  // expired
            creds(access: "geminicli", refresh: "r2", expiresInSec: 3600),  // valid
        ]
        let token = try await GeminiClient.selectToken(
            from: candidates, now: now, refresh: refresher(succeedFor: []))  // refresh always fails
        #expect(token.value == "geminicli")  // did not get stuck on the stale first source
    }

    @Test("expired first source refreshes when it can")
    func refreshesExpiredSource() async throws {
        let candidates = [creds(access: "antigravity", refresh: "r1", expiresInSec: -10)]
        let token = try await GeminiClient.selectToken(
            from: candidates, now: now, refresh: refresher(succeedFor: ["antigravity"]))
        #expect(token.value == "refreshed:antigravity")
    }

    @Test("no candidates throws")
    func noCandidatesThrows() async {
        await #expect(throws: (any Error).self) {
            try await GeminiClient.selectToken(from: [], now: now, refresh: refresher())
        }
    }
}
