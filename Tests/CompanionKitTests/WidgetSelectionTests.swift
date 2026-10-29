import XCTest
@testable import CompanionKit

final class WidgetSelectionTests: XCTestCase {
    func testButtonsDoNotChangeOtherStackConfigurations() {
        let domain = "WidgetSelectionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        XCTAssertTrue(
            CompanionWidgetSelection.set(scope: "limits.claude", value: "codex", defaults: defaults)
        )
        XCTAssertEqual(
            CompanionWidgetSelection.value(
                scope: "limits.claude", fallback: "claude", defaults: defaults), "codex")
        XCTAssertEqual(
            CompanionWidgetSelection.value(
                scope: "limits.codex", fallback: "codex", defaults: defaults), "codex")
        XCTAssertEqual(
            CompanionWidgetSelection.value(
                scope: "limits.tightest", fallback: "tightest", defaults: defaults), "tightest")
        XCTAssertTrue(
            CompanionWidgetSelection.set(
                scope: "activity.tokens.week", value: "cost", defaults: defaults))
        XCTAssertEqual(
            CompanionWidgetSelection.value(
                scope: "activity.tokens.week", fallback: "tokens", defaults: defaults), "cost")
        XCTAssertEqual(
            CompanionWidgetSelection.value(
                scope: "activity.tokens.month", fallback: "tokens", defaults: defaults), "tokens")
        XCTAssertEqual(
            CompanionWidgetSelection.value(
                scope: "activity.cost.week", fallback: "cost", defaults: defaults), "cost")
    }

    func testCachedButtonRefreshExpiresAndMalformedSelectionsCannotPersist() {
        let domain = "WidgetSelectionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let now = Date(timeIntervalSince1970: 1800000000)
        XCTAssertTrue(
            CompanionWidgetSelection.set(
                scope: "limits.tightest", value: "claude", now: now, defaults: defaults))
        XCTAssertTrue(
            CompanionWidgetSelection.recentlyChanged(
                scope: "limits.tightest", now: now.addingTimeInterval(1), defaults: defaults))
        XCTAssertFalse(
            CompanionWidgetSelection.recentlyChanged(
                scope: "limits.tightest", now: now.addingTimeInterval(31), defaults: defaults))
        XCTAssertFalse(
            CompanionWidgetSelection.recentlyChanged(
                scope: "limits.tightest", now: now.addingTimeInterval(-1), defaults: defaults))
        XCTAssertFalse(
            CompanionWidgetSelection.set(scope: "limits.claude", value: "cost", defaults: defaults))
        XCTAssertFalse(
            CompanionWidgetSelection.set(
                scope: "activity.tokens.week", value: "claude", defaults: defaults))
        XCTAssertFalse(
            CompanionWidgetSelection.set(
                scope: "activity.cost.forever", value: "cost", defaults: defaults))
        XCTAssertFalse(
            CompanionWidgetSelection.set(
                scope: "other.preference", value: "claude", defaults: defaults))
    }
}
