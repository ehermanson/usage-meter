import Foundation

/// One rate-limit window for a provider (e.g. the 5-hour rolling window).
/// `id` is derived from the (unique-per-pool) label so identity survives refetches
/// — a fresh fetch with the same window keeps its view, letting the bar animate.
struct UsageWindow: Identifiable, Equatable, Codable {
    var id: String { label }
    let label: String  // "5h", "Weekly", "7d · Sonnet"
    let usedPercent: Double  // 0...100
    let resetAt: Date?
    /// Optional caption shown where the reset countdown would go, for windows
    /// without a reset — e.g. a dollar-budget window's "$237 / $300".
    var detail: String? = nil

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

/// A provider that can't report usage because something on *this machine* needs
/// setting up — a missing CLI/runtime, or simply not being signed in. This is an
/// expected, calm state (not an error), so the UI presents it gently and points
/// the user at the fix instead of showing an alarming red message.
struct SetupHint: Equatable, Codable {
    let message: String  // "Sign in to Claude Code to track usage"
    var url: String? = nil  // optional "Set up ↗" link
}

/// Aggregated usage for a single provider.
struct ProviderUsage: Identifiable, Equatable, Codable {
    var id: String { name }  // one section per provider
    let name: String  // "Claude", "Codex"
    var pools: [UsagePool]
    var error: String? = nil
    var plan: String? = nil  // "Max", "Pro", "Pro Lite", …
    /// A soft, retryable failure (e.g. usage endpoint momentarily throttled) —
    /// the store keeps showing the last good values when this is set.
    var retryable: Bool = false
    /// Set when the provider needs user setup (tool not installed / not signed
    /// in). Rendered as a calm hint rather than an error when there are no windows.
    var setup: SetupHint? = nil
    /// False when the provider's CLI/credentials weren't found on this machine at
    /// all — the user doesn't use this tool, so its section is hidden entirely
    /// (no nudge to install something they didn't ask for). Not persisted: only
    /// successful, windowed snapshots are cached, and those are always detected.
    var detected: Bool = true

    private enum CodingKeys: String, CodingKey {
        case name, pools, error, plan, retryable, setup
    }

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

    /// The provider needs setup on this machine (tool missing / not signed in).
    /// Not retryable in the throttle sense — there's no stale value worth keeping,
    /// so the calm hint is shown until the user acts and a later probe succeeds.
    static func needsSetup(
        _ name: String, _ message: String, url: String? = nil, plan: String? = nil
    ) -> ProviderUsage {
        ProviderUsage(
            name: name, pools: [], error: nil, plan: plan, retryable: false,
            setup: SetupHint(message: message, url: url))
    }

    /// The provider's CLI/credentials aren't present on this machine at all, so
    /// the user doesn't use it. The section is hidden rather than shown with an
    /// install nudge — being a single-provider user is a fully supported state.
    static func notDetected(_ name: String) -> ProviderUsage {
        ProviderUsage(name: name, pools: [], detected: false)
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
