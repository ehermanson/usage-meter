import Foundation

/// One rate-limit window for a provider (e.g. the 5-hour rolling window).
/// `id` is derived from the (unique-per-pool) label so identity survives refetches
/// — a fresh fetch with the same window keeps its view, letting the bar animate.
struct UsageWindow: Identifiable, Equatable, Codable {
    var id: String { label }
    let label: String  // "5h", "Weekly", "7d · Sonnet"
    let usedPercent: Double  // 0...100
    let resetAt: Date?

    var clampedFraction: Double { max(0, min(1, usedPercent / 100)) }

    /// Headroom left in the window, 0...100 — the complement of `usedPercent`.
    var remainingPercent: Double { max(0, min(100, 100 - usedPercent)) }
}

/// A named group of windows. `title == nil` is the provider's default pool;
/// named pools (e.g. a per-model limit) carry a subheader.
struct UsagePool: Identifiable, Equatable, Codable {
    var id: String { title ?? "" }  // pool titles are unique within a provider
    let title: String?
    var windows: [UsageWindow]
}

/// Aggregated usage for a single provider.
struct ProviderUsage: Identifiable, Equatable, Codable {
    var id: String { name }  // one section per provider
    let name: String  // "Claude", "Codex"
    var pools: [UsagePool]
    var error: String?
    var plan: String?  // "Max", "Pro", "Pro Lite", …
    /// A soft, retryable failure (e.g. usage endpoint momentarily throttled) —
    /// the store keeps showing the last good values when this is set.
    var retryable: Bool = false

    var allWindows: [UsageWindow] { pools.flatMap { $0.windows } }

    /// The primary (5h) window, used for the compact menu-bar title.
    var fiveHour: UsageWindow? {
        allWindows.first { $0.label.localizedCaseInsensitiveContains("5h") }
            ?? allWindows.first
    }

    /// The primary weekly window (the broad "all" pool, not a model-scoped one).
    var weekly: UsageWindow? {
        allWindows.first {
            $0.label.localizedCaseInsensitiveContains("week")
                || $0.label.localizedCaseInsensitiveContains("7d")
        }
    }

    var hasWindows: Bool { !allWindows.isEmpty }

    static func ok(_ name: String, pools: [UsagePool], plan: String? = nil) -> ProviderUsage {
        ProviderUsage(name: name, pools: pools, error: nil, plan: plan)
    }

    static func failed(
        _ name: String, _ message: String,
        retryable: Bool = false, plan: String? = nil
    ) -> ProviderUsage {
        ProviderUsage(name: name, pools: [], error: message, plan: plan, retryable: retryable)
    }
}

enum Format {
    /// "resets in 3h 12m" / "resets in 2d 4h"
    static func relativeReset(_ date: Date?) -> String {
        guard let date else { return "" }
        let duration = resetDuration(date)
        return duration == "resetting…" ? duration : "resets in \(duration)"
    }

    /// Just the time-remaining part: "12m" / "3h 12m" / "2d 4h" / "resetting…".
    /// Used inline next to a window's percentage where the "resets in" prefix
    /// would cost too much width.
    static func resetDuration(_ date: Date?) -> String {
        guard let date else { return "" }
        let secs = date.timeIntervalSinceNow
        if secs <= 0 { return "resetting…" }
        let mins = Int(secs / 60)
        if mins < 60 { return "\(mins)m" }
        let hours = mins / 60
        let remMins = mins % 60
        if hours < 24 { return "\(hours)h \(remMins)m" }
        let days = hours / 24
        let remHours = hours % 24
        return "\(days)d \(remHours)h"
    }

    static func percent(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(0))))%"
    }
}
