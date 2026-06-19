import Foundation

/// One rate-limit window for a provider (e.g. the 5-hour rolling window).
struct UsageWindow: Identifiable {
    let id = UUID()
    let label: String        // "5h", "Weekly", "7d · Sonnet"
    let usedPercent: Double  // 0...100
    let resetAt: Date?

    var clampedFraction: Double { max(0, min(1, usedPercent / 100)) }
}

/// A named group of windows. `title == nil` is the provider's default pool;
/// named pools (e.g. a per-model limit) carry a subheader.
struct UsagePool: Identifiable {
    let id = UUID()
    let title: String?
    var windows: [UsageWindow]
}

/// Aggregated usage for a single provider.
struct ProviderUsage: Identifiable {
    let id = UUID()
    let name: String              // "Claude", "Codex"
    var pools: [UsagePool]
    var error: String?
    var plan: String?             // "Max", "Pro", "Pro Lite", …
    /// A soft, retryable failure (e.g. usage endpoint momentarily throttled) —
    /// the store keeps showing the last good values when this is set.
    var retryable: Bool = false

    var allWindows: [UsageWindow] { pools.flatMap { $0.windows } }

    /// The primary (5h) window, used for the compact menu-bar title.
    var fiveHour: UsageWindow? {
        allWindows.first { $0.label.localizedCaseInsensitiveContains("5h") }
            ?? allWindows.first
    }

    static func ok(_ name: String, pools: [UsagePool], plan: String? = nil) -> ProviderUsage {
        ProviderUsage(name: name, pools: pools, error: nil, plan: plan)
    }

    static func failed(_ name: String, _ message: String,
                       retryable: Bool = false, plan: String? = nil) -> ProviderUsage {
        ProviderUsage(name: name, pools: [], error: message, plan: plan, retryable: retryable)
    }
}

enum Format {
    /// "resets in 3h 12m" / "resets in 2d 4h"
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
