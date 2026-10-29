import Foundation

/// Controls are scoped by the widget's saved configuration, not by the app's
/// provider or tab. Differently configured widgets in a stack stay independent.
public enum CompanionWidgetSelection {
    private static let providers: Set<String> = ["tightest", "claude", "codex", "gemini"]
    private static let metrics: Set<String> = ["tokens", "cost"]
    private static let ranges: Set<String> = ["day", "week", "month", "quarter"]

    public static func value(scope: String, fallback: String, defaults: UserDefaults?) -> String {
        guard let value = defaults?.dictionary(forKey: key(scope))?["value"] as? String,
            valid(scope: scope, value: value)
        else { return fallback }
        return value
    }

    /// A tap refreshes from the shared cache immediately, rather than waiting on
    /// CloudKit. The normal timeline refresh resumes its network work afterward.
    public static func recentlyChanged(
        scope: String, now: Date = .now, defaults: UserDefaults?
    ) -> Bool {
        guard let record = defaults?.dictionary(forKey: key(scope)),
            let value = record["value"] as? String, valid(scope: scope, value: value),
            let date = record["changedAt"] as? Date
        else { return false }
        return (0..<30).contains(now.timeIntervalSince(date))
    }

    @discardableResult
    public static func set(
        scope: String, value: String, now: Date = .now, defaults: UserDefaults?
    ) -> Bool {
        guard let defaults, valid(scope: scope, value: value) else { return false }
        defaults.set(["value": value, "changedAt": now] as [String: Any], forKey: key(scope))
        return true
    }

    private static func key(_ scope: String) -> String { "widget.selection.\(scope)" }
    private static func valid(scope: String, value: String) -> Bool {
        let parts = scope.split(separator: ".").map(String.init)
        if parts.count == 2, parts[0] == "limits" {
            return providers.contains(parts[1]) && providers.contains(value)
        }
        if parts.count == 3, parts[0] == "activity" {
            return metrics.contains(parts[1]) && ranges.contains(parts[2])
                && metrics.contains(value)
        }
        return false
    }
}
