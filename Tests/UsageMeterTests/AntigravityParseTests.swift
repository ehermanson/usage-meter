import Foundation
import Testing

@testable import UsageMeter

@Suite("Antigravity quota parsing")
struct AntigravityParseTests {
    private func reset(hoursFromNow: Double) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date().addingTimeInterval(hoursFromNow * 3600))
    }

    @Test("parses multi-group agy /usage JSON, ordering 5h before Weekly in each pool")
    func parsesMultiGroupPayload() throws {
        let root: [String: Any] = [
            "status": "SUCCESS",
            "command": [
                "name": "usage",
                "data": [
                    "groups": [
                        [
                            "name": "Gemini Models",
                            "buckets": [
                                [
                                    "id": "gemini-weekly",
                                    "name": "Weekly Limit Remaining",
                                    "window": "weekly",
                                    "remaining_fraction": 0.62,
                                    "reset_time": reset(hoursFromNow: 160),
                                ],
                                [
                                    "id": "gemini-5h",
                                    "name": "Five Hour Limit Remaining",
                                    "window": "5h",
                                    "remaining_fraction": 0.68,
                                    "reset_time": reset(hoursFromNow: 2.5),
                                ],
                            ],
                        ],
                        [
                            "name": "Claude and GPT models",
                            "buckets": [
                                [
                                    "id": "3p-weekly",
                                    "name": "Weekly Limit Remaining",
                                    "window": "weekly",
                                    "remaining_fraction": 1.0,
                                    "reset_time": reset(hoursFromNow: 168),
                                ],
                                [
                                    "id": "3p-5h",
                                    "name": "Five Hour Limit Remaining",
                                    "window": "5h",
                                    "remaining_fraction": 0.9,
                                    "reset_time": reset(hoursFromNow: 5),
                                ],
                            ],
                        ],
                        [
                            "name": "Gemini 4 Argon",
                            "buckets": [
                                [
                                    "id": "gemini-argon-wtu-weekly",
                                    "name": "Gemini 4 Argon Weekly Limit",
                                    "window": "weekly",
                                    "remaining_fraction": 1.0,
                                    "reset_time": reset(hoursFromNow: 168),
                                ]
                            ],
                        ],
                    ]
                ],
            ],
        ]

        let usage = AntigravityClient.parse(root)
        #expect(usage.name == "Antigravity")
        #expect(usage.error == nil)
        // Gemini 4 Argon is at 0% used and hidden; Gemini Models (primary) and
        // Claude and GPT models (10% used on 5h) stay visible.
        #expect(usage.pools.count == 2)
        #expect(usage.pools.map(\.title) == ["Gemini Models", "Claude and GPT models"])

        let primary = usage.pools[0]
        #expect(primary.windows.map(\.label) == ["5h", "Weekly"])
        #expect(abs(primary.windows[0].usedPercent - 32.0) < 0.001)
        #expect(primary.windows[0].duration == TimeInterval(5 * 3600))
        #expect(abs(primary.windows[1].usedPercent - 38.0) < 0.001)
        #expect(primary.windows[1].duration == TimeInterval(7 * 24 * 3600))
        #expect(primary.windows[0].resetAt != nil)

        // Menu-bar accessors pick the primary pool's 5h and Weekly windows.
        #expect(usage.fiveHour?.label == "5h")
        #expect(abs((usage.fiveHour?.usedPercent ?? -1) - 32.0) < 0.001)
        #expect(usage.weekly?.label == "Weekly")
        #expect(abs((usage.weekly?.usedPercent ?? -1) - 38.0) < 0.001)

        // Secondary pool also sorts 5h before Weekly.
        #expect(usage.pools[1].windows.map(\.label) == ["5h", "Weekly"])
        #expect(abs(usage.pools[1].windows[0].usedPercent - 10.0) < 0.001)
    }

    @Test("unused secondary pools are hidden and the primary pool drops its subheader")
    func hidesUnusedSecondaryPools() {
        let root: [String: Any] = [
            "status": "SUCCESS",
            "command": [
                "name": "usage",
                "data": [
                    "groups": [
                        [
                            "name": "Gemini Models",
                            "buckets": [
                                [
                                    "id": "gemini-5h",
                                    "window": "5h",
                                    "remaining_fraction": 1.0,
                                    "reset_time": reset(hoursFromNow: 5),
                                ],
                                [
                                    "id": "gemini-weekly",
                                    "window": "weekly",
                                    "remaining_fraction": 1.0,
                                    "reset_time": reset(hoursFromNow: 168),
                                ],
                            ],
                        ],
                        [
                            "name": "Claude and GPT models",
                            "buckets": [
                                [
                                    "id": "3p-5h",
                                    "window": "5h",
                                    "remaining_fraction": 1.0,
                                    "reset_time": reset(hoursFromNow: 5),
                                ]
                            ],
                        ],
                    ]
                ],
            ],
        ]

        let usage = AntigravityClient.parse(root)
        // Primary pool stays visible even at 0%, without a redundant subheader.
        #expect(usage.pools.count == 1)
        #expect(usage.pools[0].title == nil)
        #expect(usage.pools[0].windows.map(\.label) == ["5h", "Weekly"])
    }

    @Test("exhausted bucket omitting remaining_fraction is treated as 100% used")
    func omittedRemainingFractionTreatedAsExhausted() {
        let root: [String: Any] = [
            "status": "SUCCESS",
            "command": [
                "name": "usage",
                "data": [
                    "groups": [
                        [
                            "name": "Gemini Models",
                            "buckets": [
                                [
                                    "id": "gemini-5h",
                                    "window": "5h",
                                    "reset_time": reset(hoursFromNow: 3),
                                ],
                                [
                                    "id": "gemini-weekly",
                                    "window": "weekly",
                                    "remaining_fraction": 0.5,
                                    "reset_time": reset(hoursFromNow: 120),
                                ],
                            ],
                        ]
                    ]
                ],
            ],
        ]

        let usage = AntigravityClient.parse(root)
        #expect(usage.pools.count == 1)
        #expect(usage.pools[0].windows.map(\.label) == ["5h", "Weekly"])
        #expect(usage.pools[0].windows[0].usedPercent == 100.0)
        #expect(usage.pools[0].windows[1].usedPercent == 50.0)
    }

    @Test("near-zero secondary pool that rounds to 0% stays hidden")
    func nearZeroSecondaryPoolHidden() {
        let root: [String: Any] = [
            "status": "SUCCESS",
            "command": [
                "name": "usage",
                "data": [
                    "groups": [
                        [
                            "name": "Gemini Models",
                            "buckets": [
                                [
                                    "id": "gemini-5h",
                                    "window": "5h",
                                    "remaining_fraction": 0.5,
                                    "reset_time": reset(hoursFromNow: 3),
                                ]
                            ],
                        ],
                        [
                            "name": "Claude and GPT models",
                            "buckets": [
                                [
                                    "id": "3p-5h",
                                    "window": "5h",
                                    "remaining_fraction": 0.9996,
                                    "reset_time": reset(hoursFromNow: 5),
                                ]
                            ],
                        ],
                    ]
                ],
            ],
        ]

        let usage = AntigravityClient.parse(root)
        #expect(usage.pools.count == 1)
        #expect(usage.pools[0].title == nil)
    }

    @Test("preface text before pretty-printed JSON still parses")
    func prefaceBeforePrettyJSON() {
        let future = reset(hoursFromNow: 4)
        let stdout = """
            Fetching usage...
            {
              "status": "SUCCESS",
              "command": {
                "name": "usage",
                "data": {
                  "groups": [
                    {
                      "name": "Gemini Models",
                      "buckets": [
                        {
                          "id": "gemini-5h",
                          "window": "5h",
                          "remaining_fraction": 0.75,
                          "reset_time": "\(future)"
                        }
                      ]
                    }
                  ]
                }
              }
            }
            """
        let usage = AntigravityClient.parseCommandResult(stdout: stdout, stderr: "", exitCode: 0)
        #expect(usage.error == nil)
        #expect(usage.fiveHour?.usedPercent == 25.0)
    }

    @Test("SUCCESS without groups returns retryable No quota data instead of raw table")
    func successMissingGroups() {
        let root: [String: Any] = [
            "status": "SUCCESS",
            "response": "Gemini Models\tWeekly\t100%\t2026-11-28T00:00:00Z",
        ]
        let usage = AntigravityClient.parse(root)
        #expect(usage.setup == nil)
        #expect(usage.error == "No quota data")
        #expect(usage.retryable)
    }

    @Test("single group omits the pool subheader")
    func singleGroupUntitled() {
        let root: [String: Any] = [
            "status": "SUCCESS",
            "command": [
                "name": "usage",
                "data": [
                    "groups": [
                        [
                            "name": "Gemini Models",
                            "buckets": [
                                [
                                    "id": "gemini-daily",
                                    "name": "Daily Limit",
                                    "window": "daily",
                                    "remaining_fraction": 0.25,
                                    "reset_time": reset(hoursFromNow: 12),
                                ]
                            ],
                        ]
                    ]
                ],
            ],
        ]

        let usage = AntigravityClient.parse(root)
        #expect(usage.pools.count == 1)
        #expect(usage.pools[0].title == nil)
        #expect(usage.allWindows.count == 1)
        #expect(usage.allWindows[0].label == "Daily")
        #expect(usage.allWindows[0].usedPercent == 75.0)
        #expect(usage.allWindows[0].duration == TimeInterval(24 * 3600))
    }

    @Test("epoch-locked buckets are skipped; no usable buckets yields retryable failure")
    func skipsEpochLockedBuckets() {
        let root: [String: Any] = [
            "status": "SUCCESS",
            "command": [
                "name": "usage",
                "data": [
                    "groups": [
                        [
                            "name": "Locked",
                            "buckets": [
                                [
                                    "id": "locked",
                                    "window": "weekly",
                                    "remaining_fraction": 0.0,
                                    "reset_time": "1970-01-01T00:00:00Z",
                                ]
                            ],
                        ]
                    ]
                ],
            ],
        ]

        let usage = AntigravityClient.parse(root)
        #expect(usage.error != nil)
        #expect(!usage.hasWindows)
        #expect(usage.retryable)
    }

    @Test("process output parsing handles sign-in, API key mode, and transient errors")
    func commandResultClassification() {
        let apiKey = AntigravityClient.parseCommandResult(
            stdout:
                #"{"status":"ERROR","response":"Account quota is unavailable when using GEMINI_API_KEY."}"#,
            stderr: "",
            exitCode: 2)
        #expect(apiKey.setup != nil)
        #expect(apiKey.setup?.url == SetupDetection.antigravityURL)
        #expect(!apiKey.retryable)

        let signedOut = AntigravityClient.parseCommandResult(
            stdout: "",
            stderr: "Authentication required. Please sign in by running agy.",
            exitCode: 1)
        #expect(signedOut.setup != nil)
        #expect(signedOut.setup?.url == SetupDetection.antigravityURL)

        let transient = AntigravityClient.parseCommandResult(
            stdout: "",
            stderr: "dial tcp: i/o timeout",
            exitCode: 1)
        #expect(transient.setup == nil)
        #expect(transient.error == "dial tcp: i/o timeout")
        #expect(transient.retryable)

        // A transport error mentioning "token" or an unstructured proxy 403 must
        // stay retryable so the store keeps showing the last good snapshot.
        let tokenTimeout = AntigravityClient.parseCommandResult(
            stdout: "",
            stderr: "failed to refresh token: dial tcp 142.250.80.10:443: i/o timeout",
            exitCode: 1)
        #expect(tokenTimeout.setup == nil)
        #expect(tokenTimeout.retryable)

        let proxy403 = AntigravityClient.parseCommandResult(
            stdout: "",
            stderr: "HTTP 403 Forbidden from corporate proxy",
            exitCode: 1)
        #expect(proxy403.setup == nil)
        #expect(proxy403.retryable)

        // Exit 0 with non-SUCCESS status is still treated as a failure.
        let zeroExitError = AntigravityClient.parseCommandResult(
            stdout: #"{"status":"ERROR","error":"Authentication expired. Please log back in."}"#,
            stderr: "",
            exitCode: 0)
        #expect(zeroExitError.setup != nil)
        #expect(!zeroExitError.retryable)
    }
}
