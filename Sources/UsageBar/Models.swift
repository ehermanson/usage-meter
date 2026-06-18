import Foundation

/// One rate-limit window for a provider (e.g. the 5-hour rolling window).
struct UsageWindow: Identifiable {
    let id = UUID()
    let label: String        // "5h", "Weekly", "7d"
    let usedPercent: Double  // 0...100
    let resetAt: Date?

    var clampedFraction: Double { max(0, min(1, usedPercent / 100)) }
}

/// Aggregated usage for a single provider.
struct ProviderUsage: Identifiable {
    let id = UUID()
    let name: String              // "Claude", "Codex"
    var windows: [UsageWindow]
    var error: String?
    var plan: String?             // "max", "Pro", "prolite", …
    /// A soft, retryable failure (e.g. usage endpoint momentarily throttled) —
    /// the store keeps showing the last good values when this is set.
    var retryable: Bool = false

    /// The primary (5h) window, used for the compact menu-bar title.
    var fiveHour: UsageWindow? {
        windows.first { $0.label.localizedCaseInsensitiveContains("5h") }
            ?? windows.first
    }

    static func failed(_ name: String, _ message: String,
                       retryable: Bool = false, plan: String? = nil) -> ProviderUsage {
        ProviderUsage(name: name, windows: [], error: message, plan: plan, retryable: retryable)
    }
}

enum Format {
    /// "in 3h 12m" / "in 2d 4h"
    static func relativeReset(_ date: Date?) -> String {
        guard let date else { return "" }
        let secs = date.timeIntervalSinceNow
        if secs <= 0 { return "resetting…" }
        let mins = Int(secs / 60)
        if mins < 60 { return "resets in \(mins)m" }
        let hours = mins / 60
        let remMins = mins % 60
        if hours < 24 { return "resets in \(hours)h \(remMins)m" }
        let days = hours / 24
        let remHours = hours % 24
        return "resets in \(days)d \(remHours)h"
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value)
    }
}
