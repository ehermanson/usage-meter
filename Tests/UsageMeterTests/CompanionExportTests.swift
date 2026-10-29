import CompanionKit
import XCTest
@testable import UsageMeter

final class CompanionExportTests: XCTestCase {
    func testExportDropsRawErrorsSetupPathsAndBudgetDetails() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let provider = ProviderUsage(
            name: "Claude",
            pools: [
                UsagePool(
                    title: nil,
                    windows: [
                        UsageWindow(
                            label: "5h", usedPercent: 42, resetAt: date,
                            detail: "/Users/private/secrets", duration: 18000)
                    ])
            ], error: "Bearer SECRET /Users/private", plan: "Max", retryable: true,
            capturedAt: date)
        let value = provider.companionValue
        XCTAssertEqual(value.capturedAt, date)
        XCTAssertEqual(value.status, .temporarilyUnavailable)
        XCTAssertEqual(value.windows.first?.usedPercent, 42)
        let json = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        XCTAssertFalse(json.contains("SECRET"))
        XCTAssertFalse(json.contains("/Users"))
    }

    func testWindowIdentitySeparatesPoolsWithSameLabels() {
        let value = ProviderUsage.ok(
            "Claude",
            pools: [
                UsagePool(
                    title: nil,
                    windows: [UsageWindow(label: "Weekly", usedPercent: 10, resetAt: nil)]),
                UsagePool(
                    title: "Sonnet",
                    windows: [UsageWindow(label: "Weekly", usedPercent: 20, resetAt: nil)]),
            ]
        ).companionValue
        XCTAssertEqual(Set(value.windows.map(\.id)).count, 2)
    }
}
